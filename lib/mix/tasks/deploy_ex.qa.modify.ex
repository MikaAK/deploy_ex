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
           {:ok, modified} <- apply_modifications(qa_node, opts) do
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
