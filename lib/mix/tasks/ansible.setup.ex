defmodule Mix.Tasks.Ansible.Setup do
  use Mix.Task

  @ansible_default_path DeployEx.Config.ansible_folder_path()
  @setup_timeout :timer.minutes(30)
  @setup_max_concurrency 4

  @shortdoc "Initial setup and configuration of Ansible hosts"
  @moduledoc """
  Performs initial setup and configuration of Ansible hosts. This task should be run once
  when new nodes are created.

  The setup process includes:
  - Installing required system packages (awscli, python, pip)
  - Configuring VM settings for optimal BEAM and TCP performance
  - Setting up log rotation
  - Configuring S3 crash dump uploads
  - Setting up server cleanup on termination
  - Installing the application release as a SystemD service

  ### QA nodes

  With `--include-qa`, QA nodes are picked up from the aws_ec2 inventory and
  per-node context (Let's Encrypt cert mode, release prefix, git branch) is
  derived automatically from their EC2 tags via inventory `compose:` mappings
  — no extra flags or per-node playbooks needed. Nodes tagged
  `UsePublicIpCert=true` (set by `mix deploy_ex.qa.create --public-ip-cert`)
  will issue a Let's Encrypt cert against the node's public IP instead of a
  DNS-based domain cert.

  ### Targeting a single instance

  Pass `--instance-id i-0abc123` (alias `-i`, repeatable) to scope the setup
  to a specific EC2 instance. Each id is resolved to its `Name` tag via the
  AWS API and combined into an ansible `--limit '<name1>,<name2>,'` so every
  setup playbook only touches the matching host(s). The default `!qa_true`
  exclusion is bypassed when targeting by id, so a QA instance can be
  re-bootstrapped without also passing `--include-qa`.

  ### Targeting QA nodes for a git branch

  Pass `--git-branch qa/<name>` (alias `-b`) to scope the setup to every QA
  node tagged with that `GitBranch`. The branch is resolved via the AWS API
  to the matching QA `Name` tags and merged into the same ansible `--limit`
  used by `--instance-id`. Errors if no QA node matches. Bypasses the default
  `!qa_true` exclusion (a branch-scoped run is QA by definition). Combine
  with `--instance-id` to add ad-hoc hosts to the same run.

  ## Example
  ```bash
  mix ansible.setup
  mix ansible.setup --only app1 --only app2
  mix ansible.setup --except app3
  mix ansible.setup --include-qa
  mix ansible.setup --instance-id i-0abc1234567890def
  mix ansible.setup -i i-0abc1234567890def -i i-0fed9876543210cba
  mix ansible.setup --git-branch qa/gamma_charts
  mix ansible.setup -b qa/gamma_charts -i i-0abc1234567890def
  ```

  ## Options
  - `directory` - Directory containing ansible playbooks (default: ./deploys/ansible)
  - `parallel` - Maximum number of concurrent setup operations (default: 4)
  - `only` - Only setup specified apps (can be used multiple times)
  - `except` - Skip setup for specified apps (can be used multiple times)
  - `include-qa` - Include QA nodes in setup (default: excluded)
  - `instance-id, -i` - Target one or more EC2 instances by instance id
    (repeatable; resolves each id to its `Name` tag and passes them as a
    single ansible `--limit`). Bypasses the default QA exclusion.
  - `git-branch, -b` - Target every QA node whose `GitBranch` tag matches.
    Resolves to matching QA `Name` tags via the AWS API and merges them into
    the ansible `--limit`. Bypasses the default QA exclusion.
  - `aws-region` - AWS region for the instance lookup (default: from config)
  - `no-tui` - Disable TUI progress display
  - `quiet` - Suppress output messages
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_valid_project(),
         :ok <- DeployEx.ToolInstaller.ensure_installed(:ansible) do
      opts = args
        |> parse_args
        |> Keyword.put_new(:directory, @ansible_default_path)
        |> Keyword.put_new(:parallel, @setup_max_concurrency)

      instance_ids = Keyword.get_values(opts, :instance_id)
      git_branch = opts[:git_branch]

      opts = opts
        |> Keyword.put(:only, Keyword.get_values(opts, :only))
        |> Keyword.put(:except, Keyword.get_values(opts, :except))
        |> Keyword.put(:instance_id, instance_ids)

      ansible_args = args
        |> DeployEx.Ansible.parse_args()
        |> then(fn
          "" -> []
          arg -> [arg]
        end)

      ansible_args = ansible_args ++ build_target_limit(instance_ids, git_branch, opts)

      DeployExHelpers.check_file_exists!(Path.join(opts[:directory], "aws_ec2.yaml"))

      DeployEx.TUI.setup_no_tui(opts)

      relative_directory = String.replace(Path.absname(opts[:directory]), "#{File.cwd!()}/", "")

      setup_files = opts[:directory]
        |> Path.join("setup/*.yaml")
        |> Path.wildcard
        |> Enum.map(&Path.relative_to(&1, relative_directory))
        |> DeployExHelpers.filter_only_or_except(opts[:only], opts[:except])

      if Enum.empty?(setup_files) do
        Mix.shell().info([:yellow, "Nothing to setup"])
      else
        run_fn = fn setup_file, line_callback ->
          command = build_setup_command(setup_file, ansible_args, opts)
          DeployEx.Utils.run_command_streaming(command, opts[:directory], line_callback)
        end

        res = DeployEx.TUI.DeployProgress.run(setup_files, run_fn,
          max_concurrency: opts[:parallel],
          timeout: @setup_timeout
        )

        case res do
          {:ok, _} -> :ok

          {:error, [head | tail]} ->
            Enum.each(tail, &Mix.shell().error(to_string(&1)))
            Mix.raise(to_string(head))

          {:error, error} ->
            Mix.raise(to_string(error))
        end
      end
    end
  end

  defp build_setup_command(setup_file, ansible_args, opts) do
    has_custom_limit = Enum.any?(ansible_args, &String.contains?(&1, "--limit"))
    targeted_by_id = not Enum.empty?(opts[:instance_id] || [])
    targeted_by_branch = is_binary(opts[:git_branch])
    skip_qa_filter = opts[:include_qa] === true or has_custom_limit or targeted_by_id or targeted_by_branch
    qa_limit = if skip_qa_filter, do: [], else: ["--limit", "'!qa_true'"]

    (["ansible-playbook", setup_file] ++ ansible_args ++ qa_limit)
    |> Enum.join(" ")
  end

  defp build_target_limit([], nil, _opts), do: []
  defp build_target_limit(instance_ids, git_branch, opts) do
    ensure_aws_started()

    names =
      resolve_instance_id_names(instance_ids, opts) ++
        resolve_git_branch_names(git_branch, opts)

    case Enum.uniq(names) do
      [] -> []
      uniq_names -> ["--limit", "'#{Enum.join(uniq_names, ",")},'"]
    end
  end

  defp ensure_aws_started do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)
  end

  defp resolve_instance_id_names([], _opts), do: []
  defp resolve_instance_id_names(instance_ids, opts) do
    region = opts[:aws_region] || DeployEx.Config.aws_region()

    case DeployEx.AwsMachine.find_instances_by_id(region, instance_ids) do
      {:ok, instances} ->
        extract_instance_names(instances, instance_ids)

      {:error, error} ->
        Mix.raise("Failed to resolve --instance-id #{inspect(instance_ids)}: #{ErrorMessage.to_string(error)}")
    end
  end

  defp resolve_git_branch_names(nil, _opts), do: []
  defp resolve_git_branch_names(branch, opts) do
    lookup_opts = [region: opts[:aws_region] || DeployEx.Config.aws_region()]

    case DeployEx.QaNode.find_qa_nodes_by_branch(branch, lookup_opts) do
      {:ok, []} ->
        Mix.raise("No QA nodes found for --git-branch #{inspect(branch)}")

      {:ok, nodes} ->
        Enum.map(nodes, & &1.instance_name)

      {:error, error} ->
        Mix.raise("Failed to resolve --git-branch #{inspect(branch)}: #{ErrorMessage.to_string(error)}")
    end
  end

  defp extract_instance_names(instances, requested_ids) do
    found = Map.new(instances, fn instance -> {instance["instanceId"], instance_name(instance)} end)

    missing = Enum.filter(requested_ids, &is_nil(found[&1]))

    unless Enum.empty?(missing) do
      Mix.raise("No EC2 instances found for --instance-id: #{Enum.join(missing, ", ")}")
    end

    Enum.map(requested_ids, &Map.fetch!(found, &1))
  end

  defp instance_name(%{"tagSet" => %{"item" => items}}) when is_list(items) do
    Enum.find_value(items, fn %{"key" => key, "value" => value} ->
      if key === "Name", do: value
    end)
  end

  defp instance_name(%{"tagSet" => %{"item" => %{"key" => "Name", "value" => value}}}), do: value
  defp instance_name(_), do: nil

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, i: :instance_id, b: :git_branch],
      switches: [
        directory: :string,
        only: :keep,
        except: :keep,
        force: :boolean,
        quiet: :boolean,
        parallel: :integer,
        include_qa: :boolean,
        instance_id: :keep,
        git_branch: :string,
        aws_region: :string,
        no_tui: :boolean
      ]
    )

    opts
  end
end
