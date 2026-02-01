defmodule Mix.Tasks.DeployEx.Qa.Create do
  use Mix.Task

  @shortdoc "Creates a new QA node with a specific SHA"
  @moduledoc """
  Creates a new QA node for a specific app and SHA.

  The QA node is a standalone EC2 instance that runs a specific release
  version for testing purposes.

  ## Example
  ```bash
  mix deploy_ex.qa.create my_app --sha abc1234
  mix deploy_ex.qa.create my_app --sha abc1234 --attach-lb
  mix deploy_ex.qa.create my_app --sha abc1234 --skip-setup --skip-deploy
  ```

  ## Options
  - `--sha, -s` - Target git SHA (required)
  - `--instance-type` - EC2 instance type (default: t3.small)
  - `--skip-setup` - Skip Ansible setup after creation
  - `--skip-deploy` - Skip deployment after setup
  - `--attach-lb` - Attach to load balancer after deployment
  - `--force, -f` - Replace existing QA node without prompting
  - `--quiet, -q` - Suppress output messages
  - `--aws-region` - AWS region (default: from config)
  - `--aws-release-bucket` - S3 bucket for releases (default: from config)
  """

  @ansible_default_path DeployEx.Config.ansible_folder_path()

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      app_name = case extra_args do
        [name | _] -> name
        [] -> Mix.raise("App name is required. Usage: mix deploy_ex.qa.create <app_name> --sha <sha>")
      end

      sha = opts[:sha] || Mix.raise("--sha option is required")

      with :ok <- validate_app_name(app_name),
           {:ok, full_sha} <- validate_and_find_sha(app_name, sha, opts),
           :ok <- check_existing_qa_node(app_name, opts),
           {:ok, infra} <- gather_infrastructure(opts),
           {:ok, qa_node} <- create_qa_node(app_name, full_sha, infra, opts),
           :ok <- wait_for_instance(qa_node, opts),
           {:ok, qa_node} <- save_and_refresh_state(qa_node, opts),
           :ok <- maybe_run_setup(qa_node, opts),
           :ok <- maybe_run_deploy(qa_node, full_sha, opts),
           {:ok, qa_node} <- maybe_attach_lb(qa_node, opts) do
        output_success(qa_node, opts)
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :sha, f: :force, q: :quiet],
      switches: [
        sha: :string,
        instance_type: :string,
        skip_setup: :boolean,
        skip_deploy: :boolean,
        attach_lb: :boolean,
        force: :boolean,
        quiet: :boolean,
        aws_region: :string,
        aws_release_bucket: :string
      ]
    )
  end

  defp validate_app_name(app_name) do
    case DeployExHelpers.fetch_mix_releases() do
      {:ok, releases} ->
        release_names = releases |> Keyword.keys() |> Enum.map(&to_string/1)

        if app_name in release_names do
          :ok
        else
          {:error, ErrorMessage.not_found("app '#{app_name}' not found in mix releases", %{available: release_names})}
        end

      {:error, e} ->
        {:error, ErrorMessage.failed_dependency("failed to fetch mix releases: #{e}")}
    end
  end

  defp validate_and_find_sha(app_name, sha, opts) do
    fetch_opts = [
      aws_release_bucket: opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket(),
      aws_region: opts[:aws_region] || DeployEx.Config.aws_region()
    ]

    case DeployEx.ReleaseUploader.fetch_all_remote_releases(fetch_opts) do
      {:ok, releases} ->
        app_releases = Enum.filter(releases, &String.contains?(&1, app_name))
        matching = Enum.find(app_releases, &String.contains?(&1, sha))

        case matching do
          nil ->
            suggestions = DeployExHelpers.format_release_suggestions(app_releases, sha)
            {:error, ErrorMessage.not_found("no release found matching SHA '#{sha}' for app '#{app_name}'", %{suggestions: suggestions})}

          release ->
            case DeployExHelpers.extract_sha_from_release(release) do
              nil -> {:error, ErrorMessage.bad_request("couldn't extract SHA from release name")}
              full_sha -> {:ok, full_sha}
            end
        end

      {:error, _} = error ->
        error
    end
  end


  defp check_existing_qa_node(app_name, opts) do
    case DeployEx.QaNode.fetch_qa_state(app_name) do
      {:ok, nil} ->
        :ok

      {:ok, existing} ->
        if opts[:force] do
          Mix.shell().info([:yellow, "Destroying existing QA node #{existing.instance_id}..."])
          DeployEx.QaNode.terminate_qa_node(existing)
          :ok
        else
          {:error, ErrorMessage.conflict(
            "QA node already exists for #{app_name}. Use --force to replace.",
            %{instance_id: existing.instance_id, sha: existing.target_sha}
          )}
        end

      {:error, _} = error ->
        error
    end
  end

  defp gather_infrastructure(opts) do
    Mix.shell().info("Gathering infrastructure details from AWS...")
    DeployEx.AwsInfrastructure.gather_infrastructure(opts)
  end

  defp create_qa_node(app_name, sha, infra, opts) do
    Mix.shell().info("Creating QA node for #{app_name} with SHA #{String.slice(sha, 0, 7)}...")

    params = %{
      ami_id: infra.ami_id,
      security_group_id: infra.security_group_id,
      subnet_id: infra.subnet_id,
      key_name: infra.key_name,
      iam_instance_profile: infra.iam_instance_profile,
      instance_type: opts[:instance_type]
    }

    DeployEx.QaNode.create_instance(app_name, sha, params, opts)
  end

  defp wait_for_instance(qa_node, _opts) do
    Mix.shell().info("Waiting for instance #{qa_node.instance_id} to start...")
    DeployEx.AwsMachine.wait_for_started([qa_node.instance_id])
  end

  defp save_and_refresh_state(qa_node, opts) do
    with {:ok, :saved} <- DeployEx.QaNode.save_qa_state(qa_node.app_name, qa_node, opts),
         {:ok, refreshed} <- DeployEx.QaNode.verify_instance_exists(qa_node) do
      {:ok, refreshed}
    end
  end

  defp maybe_run_setup(_qa_node, %{skip_setup: true}), do: :ok
  defp maybe_run_setup(qa_node, opts) do
    Mix.shell().info("Running Ansible setup for #{qa_node.instance_name}...")
    run_ansible_setup(qa_node, opts)
  end

  defp maybe_run_deploy(_qa_node, _sha, %{skip_deploy: true}), do: :ok
  defp maybe_run_deploy(qa_node, sha, opts) do
    Mix.shell().info("Deploying SHA #{String.slice(sha, 0, 7)} to #{qa_node.instance_name}...")
    run_ansible_deploy(qa_node, sha, opts)
  end

  defp maybe_attach_lb(qa_node, %{attach_lb: true} = opts) do
    Mix.shell().info("Attaching to load balancer...")

    with {:ok, target_groups} <- DeployEx.AwsLoadBalancer.find_target_groups_by_app(qa_node.app_name, opts) do
      if Enum.empty?(target_groups) do
        Mix.shell().info([:yellow, "No target groups found for #{qa_node.app_name}"])
        {:ok, qa_node}
      else
        arns = Enum.map(target_groups, & &1.arn)
        DeployEx.QaNode.attach_to_load_balancer(qa_node, arns, opts)
      end
    end
  end
  defp maybe_attach_lb(qa_node, _opts), do: {:ok, qa_node}

  defp run_ansible_setup(qa_node, _opts) do
    directory = @ansible_default_path
    setup_playbook = "setup/#{qa_node.app_name}.yaml"

    command = [
      "ansible-playbook",
      setup_playbook,
      "--limit", "'#{qa_node.instance_name}'"
    ] |> Enum.join(" ")

    case DeployEx.Utils.run_command(command, directory) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, ErrorMessage.failed_dependency("ansible setup failed", %{error: error})}
    end
  end

  defp run_ansible_deploy(qa_node, sha, _opts) do
    directory = @ansible_default_path
    playbook = "playbooks/#{qa_node.app_name}.yaml"

    command = [
      "ansible-playbook",
      playbook,
      "--limit", "'#{qa_node.instance_name}'",
      "--extra-vars", "\"target_release_sha=#{sha}\""
    ] |> Enum.join(" ")

    case DeployEx.Utils.run_command(command, directory) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, ErrorMessage.failed_dependency("ansible deploy failed", %{error: error})}
    end
  end

  defp output_success(qa_node, _opts) do
    Mix.shell().info([
      :green, "\n✓ QA node created successfully!\n",
      :reset, "\n",
      "  Instance ID: ", :cyan, qa_node.instance_id, :reset, "\n",
      "  Instance Name: ", :cyan, qa_node.instance_name, :reset, "\n",
      "  App: ", :cyan, qa_node.app_name, :reset, "\n",
      "  SHA: ", :cyan, qa_node.target_sha, :reset, "\n",
      "  Public IP: ", :cyan, to_string(qa_node.public_ip || "pending"), :reset, "\n",
      "  IPv6: ", :cyan, to_string(qa_node.ipv6_address || "pending"), :reset, "\n",
      "  LB Attached: ", :cyan, to_string(qa_node.load_balancer_attached?), :reset, "\n",
      "\n",
      "  SSH: ", :yellow, "ssh admin@#{qa_node.public_ip || qa_node.ipv6_address}", :reset, "\n"
    ])
  end
end
