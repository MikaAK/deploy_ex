defmodule Mix.Tasks.DeployEx.Qa.Modify do
  use Mix.Task

  @shortdoc "Modifies an existing QA node (size, EBS, Elastic IP, public-IP cert)"
  @moduledoc """
  Modifies an existing QA node in place. Each modification is opt-in via a flag;
  combine as many as you like in one run. Nothing happens unless at least one
  modification flag is given.

  ## Modifications
  - `--instance-type` - Resize to a new EC2 instance type. Requires a stop/start,
    so the node is briefly offline and (without an Elastic IP) gets a new public IP.
  - `--grow-root` - Grow the root EBS volume to N gigabytes (online; the filesystem
    extends on next boot via cloud-init, so pair with `--instance-type` or reboot).
  - `--elastic-ip` - Allocate + associate a VPC Elastic IP so the public IP is
    stable across stop/start (resizes).
  - `--public-ip-cert` / `--no-public-ip-cert` - Toggle the `UsePublicIpCert` tag
    that drives Let's Encrypt cert issuance for the node's public IP.

  ## Automatic cert re-issue on IP change

  A resize (or the first `--elastic-ip` association) changes the node's public IP,
  and the short-lived Let's Encrypt IP cert is scoped to the literal public IPv4 —
  so after the IP changes the node keeps serving the OLD IP's cert and browsers
  fail with `ERR_CERT_COMMON_NAME_INVALID`. When a modification changes the public
  IP AND the node is in public-IP cert mode (`use_public_ip_cert?` /
  `--public-ip-cert`), this task automatically re-issues the cert for the new IP as
  part of the same run: it re-runs the node's Ansible setup play limited to that
  host, which re-provisions the Let's Encrypt cert and prunes the stale old-IP
  lineage. Nodes not in cert mode (or `--no-public-ip-cert`) are left untouched.

  ## Example
  ```bash
  mix deploy_ex.qa.modify my_app --instance-type t3.large
  mix deploy_ex.qa.modify my_app --grow-root 30
  mix deploy_ex.qa.modify my_app --instance-type t3.large --elastic-ip
  mix deploy_ex.qa.modify --instance-id i-abc123 --public-ip-cert
  ```

  ## Options
  - `--instance-id` - EC2 instance ID to target directly (skips QA state lookup)
  - `--instance-type` - New EC2 instance type (e.g. t3.large)
  - `--grow-root` - New root EBS volume size in GB (integer)
  - `--elastic-ip` - Allocate + associate a stable Elastic IP
  - `--public-ip-cert` - Enable (or `--no-public-ip-cert` to disable) the public-IP cert tag
  - `--region` - AWS region (defaults to the configured region)
  - `--quiet, -q` - Suppress progress output
  """

  @ansible_default_path DeployEx.Config.ansible_folder_path()

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_valid_project() do
      {opts, extra_args} = parse_args(args)
      app_name = List.first(extra_args)

      unless any_modification?(opts) do
        Mix.raise(
          "No modification requested. Pass at least one of --instance-type, --grow-root, --elastic-ip, --public-ip-cert."
        )
      end

      with {:ok, qa_node} <- resolve_qa_node(app_name, opts),
           {:ok, modified} <- apply_modifications(qa_node, opts),
           {:ok, modified} <- reissue_public_ip_cert_if_needed(modified, qa_node.public_ip, opts) do
        print_summary(modified, opts)
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [q: :quiet],
      switches: [
        instance_id: :string,
        instance_type: :string,
        grow_root: :integer,
        elastic_ip: :boolean,
        public_ip_cert: :boolean,
        region: :string,
        quiet: :boolean
      ]
    )
  end

  defp any_modification?(opts) do
    [opts[:instance_type], opts[:grow_root], opts[:elastic_ip], opts[:public_ip_cert]]
    |> Enum.any?(&(not is_nil(&1)))
  end

  defp resolve_qa_node(app_name, opts) do
    cond do
      is_binary(opts[:instance_id]) ->
        resolve_by_instance_id(app_name, opts[:instance_id])

      is_binary(app_name) ->
        resolve_by_app_name(app_name, opts)

      true ->
        Mix.raise(
          "App name or --instance-id is required. Usage: mix deploy_ex.qa.modify <app_name> [flags] or mix deploy_ex.qa.modify --instance-id <id> [flags]"
        )
    end
  end

  defp resolve_by_instance_id(app_name, instance_id) do
    %DeployEx.QaNode{instance_id: instance_id, app_name: app_name}
    |> DeployEx.QaNode.verify_instance_exists()
    |> case do
      {:ok, nil} -> {:error, ErrorMessage.not_found("no running instance found for '#{instance_id}'")}
      {:ok, %DeployEx.QaNode{} = qa_node} -> {:ok, qa_node}
      error -> error
    end
  end

  defp resolve_by_app_name(app_name, opts) do
    case DeployEx.QaNode.fetch_qa_state(app_name, opts) do
      {:ok, nil} -> {:error, ErrorMessage.not_found("no QA node found for app '#{app_name}'")}
      {:ok, %DeployEx.QaNode{} = qa_node} -> DeployEx.QaNode.verify_instance_exists(qa_node)
      error -> error
    end
  end

  # Order matters: grow the EBS first (online), then resize (the stop/start lets
  # cloud-init extend the filesystem), then associate the Elastic IP onto the
  # running instance, then flip the cert tag.
  defp apply_modifications(qa_node, opts) do
    with {:ok, node} <- maybe_grow_root(qa_node, opts),
         {:ok, node} <- maybe_resize(node, opts),
         {:ok, node} <- maybe_associate_eip(node, opts),
         {:ok, node} <- maybe_set_public_ip_cert(node, opts) do
      {:ok, node}
    end
  end

  defp maybe_grow_root(node, opts) do
    case opts[:grow_root] do
      nil ->
        {:ok, node}

      size_gb ->
        announce(opts, "Growing root EBS volume to #{size_gb}GB...")
        DeployEx.QaNode.grow_root_volume(node, size_gb, opts)
    end
  end

  defp maybe_resize(node, opts) do
    case opts[:instance_type] do
      nil ->
        {:ok, node}

      instance_type ->
        announce(opts, "Resizing #{node.instance_id} to #{instance_type} (stop → modify → start)...")
        DeployEx.QaNode.resize_instance(node, instance_type, opts)
    end
  end

  defp maybe_associate_eip(node, opts) do
    if opts[:elastic_ip] do
      announce(opts, "Allocating + associating Elastic IP...")
      DeployEx.QaNode.allocate_and_associate_eip(node, opts)
    else
      {:ok, node}
    end
  end

  defp maybe_set_public_ip_cert(node, opts) do
    case opts[:public_ip_cert] do
      nil ->
        {:ok, node}

      enabled? ->
        announce(opts, "Setting UsePublicIpCert tag to #{enabled?}...")
        DeployEx.QaNode.set_use_public_ip_cert(node, enabled?, opts)
    end
  end

  # Re-issue the public-IP Let's Encrypt cert when a modification changed the
  # node's public IP and it is in cert mode — otherwise the node keeps serving
  # the old IP's cert (ERR_CERT_COMMON_NAME_INVALID). Public + `@doc false` so
  # the branch decision can be driven with an injected `:recert_fn` in tests.
  @doc false
  def reissue_public_ip_cert_if_needed(%DeployEx.QaNode{} = node, previous_public_ip, opts) do
    if DeployEx.QaNode.public_ip_cert_reissue_needed?(node, previous_public_ip) do
      announce(
        opts,
        "Public IP changed (#{previous_public_ip || "—"} → #{node.public_ip}); re-issuing Let's Encrypt cert on the node..."
      )

      recert_fn = Keyword.get(opts, :recert_fn, &run_recert_ansible/2)
      recert_fn.(node, opts)
    else
      {:ok, node}
    end
  end

  defp run_recert_ansible(%DeployEx.QaNode{} = node, opts) do
    with :ok <- DeployEx.ToolInstaller.ensure_installed(:ansible) do
      directory = @ansible_default_path

      DeployEx.QaPlaybook.with_temp_playbook(node, :setup, [letsencrypt_use_public_ip: true], directory, fn rel_path ->
        run_recert_playbook(rel_path, node, directory, opts)
      end)
    end
  end

  defp run_recert_playbook(rel_path, node, directory, opts) do
    with :ok <- refresh_ansible_inventory(directory) do
      command = "ansible-playbook #{rel_path} --limit '#{DeployEx.QaNode.ansible_limit_pattern(node)},'"

      case DeployEx.Utils.run_command_streaming(command, directory, recert_line_callback(opts)) do
        :ok -> {:ok, node}
        {:error, error} -> {:error, ErrorMessage.failed_dependency("public-IP cert re-issue failed", %{error: error})}
      end
    end
  end

  # The resize just changed the node's public IP, so the aws_ec2 dynamic
  # inventory must be re-read (cache bypassed) or ansible would SSH to the old
  # address.
  defp refresh_ansible_inventory(directory) do
    case DeployEx.Utils.run_command_with_return(
           "ANSIBLE_INVENTORY_CACHE=False ansible-inventory --list > /dev/null",
           directory
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        {:error,
         ErrorMessage.failed_dependency(
           "public-IP cert re-issue failed: ansible-inventory refresh exited non-zero",
           %{error: error}
         )}
    end
  end

  defp recert_line_callback(opts) do
    if opts[:quiet], do: fn _line -> :ok end, else: fn line -> Mix.shell().info(line) end
  end

  defp announce(opts, message) do
    unless opts[:quiet], do: Mix.shell().info(message)
  end

  defp print_summary(%DeployEx.QaNode{} = node, opts) do
    unless opts[:quiet] do
      Mix.shell().info([
        :green,
        "\n✓ Modified ",
        :cyan,
        node.instance_id,
        :reset,
        "\n  Public IP: #{node.public_ip || "—"}\n  State: #{node.state || "—"}"
      ])
    end
  end
end
