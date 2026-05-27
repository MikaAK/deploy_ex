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
  to a specific EC2 instance. The id is validated against the AWS API and
  passed to ansible as a glob: `--limit '<id1>*,<id2>*,'`. The aws_ec2
  inventory plugin composes hostnames as `<instance-id>-<Name>`, so the
  glob matches the host regardless of what the `Name` tag contains
  (including whitespace, which would otherwise break ansible's `--limit`
  parser). The default `!qa_true` exclusion is bypassed when targeting by
  id, so a QA instance can be re-bootstrapped without also passing
  `--include-qa`.

  ### Targeting QA nodes for a git branch

  Pass `--git-branch qa/<name>` (alias `-b`) to scope the setup to every QA
  node tagged with that `GitBranch`. The branch is resolved via the AWS API
  to the matching QA instance ids, and each id is added to the ansible
  `--limit` as a glob (same form as `--instance-id`). Errors if no QA node
  matches. Bypasses the default `!qa_true` exclusion (a branch-scoped run
  is QA by definition). Combine with `--instance-id` to add ad-hoc hosts
  to the same run.

  ### Auto-resolving the QA release

  When `--instance-id` or `--git-branch` is supplied the task derives the
  target branch (from `--git-branch`, or from the `GitBranch` tag on the
  targeted instances), looks up the newest QA release for each setup
  playbook's app on that branch, and passes it to ansible as
  `--extra-vars "target_release_sha=<sha>"`. Setup playbooks that do not
  represent an app (e.g. `users.yaml`, `sysctl.yaml`) are skipped silently.
  Conflicting `GitBranch` tags across targeted instances — or a mismatch
  between `--git-branch` and the targeted instances' tags — raise.

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
    (repeatable; validated against AWS and passed to ansible as a glob
    `--limit '<id1>*,<id2>*,'` matching the inventory hostname prefix).
    Bypasses the default QA exclusion.
  - `git-branch, -b` - Target every QA node whose `GitBranch` tag matches.
    Resolves to matching QA instance ids via the AWS API and adds each as
    a glob to the ansible `--limit`. Bypasses the default QA exclusion.
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

      targets = resolve_targets(instance_ids, git_branch, opts)
      ansible_args = ansible_args ++ build_limit_args(targets.patterns)

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
        release_shas = resolve_release_shas(setup_files, targets.branch, opts)
        announce_release_shas(release_shas, targets.branch, opts)

        run_fn = fn setup_file, line_callback ->
          command = build_setup_command(setup_file, ansible_args, release_shas, opts)
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

  defp build_setup_command(setup_file, ansible_args, release_shas, opts) do
    has_custom_limit = Enum.any?(ansible_args, &String.contains?(&1, "--limit"))
    targeted_by_id = not Enum.empty?(opts[:instance_id] || [])
    targeted_by_branch = is_binary(opts[:git_branch])
    skip_qa_filter = opts[:include_qa] === true or has_custom_limit or targeted_by_id or targeted_by_branch
    qa_limit = if skip_qa_filter, do: [], else: ["--limit", "'!qa_true'"]
    release_extra_vars = build_release_extra_vars(setup_file, release_shas)

    (["ansible-playbook", setup_file] ++ ansible_args ++ qa_limit ++ release_extra_vars)
    |> Enum.join(" ")
  end

  defp build_release_extra_vars(setup_file, release_shas) do
    case release_shas[app_name_from_setup_file(setup_file)] do
      nil -> []
      sha -> ["--extra-vars", "\"target_release_sha=#{sha}\""]
    end
  end

  defp build_limit_args([]), do: []
  defp build_limit_args(patterns), do: ["--limit", "'#{Enum.join(patterns, ",")},'"]

  defp resolve_targets([], nil, _opts), do: %{patterns: [], branch: nil}
  defp resolve_targets(instance_ids, git_branch, opts) do
    ensure_aws_started()
    region = opts[:aws_region] || DeployEx.Config.aws_region()

    id_nodes = lookup_instance_id_nodes(instance_ids, region)
    branch_nodes = lookup_branch_nodes(git_branch, region)
    all_nodes = id_nodes ++ branch_nodes

    patterns =
      all_nodes
      |> Enum.map(&DeployEx.QaNode.ansible_limit_pattern/1)
      |> Enum.uniq()

    %{patterns: patterns, branch: derive_branch(all_nodes, git_branch)}
  end

  defp ensure_aws_started do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)
  end

  defp lookup_instance_id_nodes([], _region), do: []
  defp lookup_instance_id_nodes(instance_ids, region) do
    case DeployEx.AwsMachine.find_instances_by_id(region, instance_ids) do
      {:ok, instances} ->
        verify_instances_found(instances, instance_ids)
        Enum.map(instances, &DeployEx.QaNode.build_qa_node_from_instance/1)

      {:error, error} ->
        Mix.raise("Failed to resolve --instance-id #{inspect(instance_ids)}: #{ErrorMessage.to_string(error)}")
    end
  end

  defp lookup_branch_nodes(nil, _region), do: []
  defp lookup_branch_nodes(branch, region) do
    case DeployEx.QaNode.find_qa_nodes_by_branch(branch, region: region) do
      {:ok, []} ->
        Mix.raise("No QA nodes found for --git-branch #{inspect(branch)}")

      {:ok, nodes} ->
        nodes

      {:error, error} ->
        Mix.raise("Failed to resolve --git-branch #{inspect(branch)}: #{ErrorMessage.to_string(error)}")
    end
  end

  defp verify_instances_found(instances, requested_ids) do
    found_ids = MapSet.new(instances, & &1["instanceId"])
    missing = Enum.reject(requested_ids, &MapSet.member?(found_ids, &1))

    unless Enum.empty?(missing) do
      Mix.raise("No EC2 instances found for --instance-id: #{Enum.join(missing, ", ")}")
    end
  end

  @doc false
  def derive_branch(nodes, git_branch_flag) do
    node_branches =
      nodes
      |> Enum.map(& &1.git_branch)
      |> Enum.filter(&(is_binary(&1) and &1 !== ""))
      |> Enum.uniq()

    candidates =
      [git_branch_flag | node_branches]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case candidates do
      [] -> nil
      [branch] -> branch
      multiple ->
        Mix.raise("Conflicting GitBranch across targeted instances: #{inspect(multiple)}")
    end
  end

  defp resolve_release_shas(_setup_files, nil, _opts), do: %{}
  defp resolve_release_shas(setup_files, branch, opts) do
    lookup_opts = [
      aws_region: opts[:aws_region] || DeployEx.Config.aws_region(),
      aws_release_bucket: DeployEx.Config.aws_release_bucket(),
      branch: branch
    ]

    setup_files
    |> Enum.map(&app_name_from_setup_file/1)
    |> Enum.uniq()
    |> Enum.flat_map(&resolve_release_sha_for_app(&1, lookup_opts))
    |> Map.new()
  end

  defp resolve_release_sha_for_app(app_name, lookup_opts) do
    case DeployEx.ReleaseLookup.resolve_sha(app_name, :qa, :auto, lookup_opts) do
      {:ok, sha} -> [{app_name, sha}]
      {:error, _} -> []
    end
  end

  defp announce_release_shas(release_shas, _branch, _opts) when map_size(release_shas) === 0, do: :ok
  defp announce_release_shas(release_shas, branch, opts) do
    unless opts[:quiet] do
      header =
        IO.ANSI.format(
          [
            :faint, "Auto-resolved QA releases for ",
            :yellow, :bright, branch, :reset, :faint, ":", :reset
          ],
          true
        )

      Mix.shell().info(to_string(header))

      release_shas
      |> Enum.sort()
      |> Enum.each(fn {app, sha} ->
        line =
          IO.ANSI.format(
            ["  ", :yellow, :bright, app, :reset, " → ", :cyan, sha, :reset],
            true
          )

        Mix.shell().info(to_string(line))
      end)
    end
  end

  defp app_name_from_setup_file(setup_file) do
    setup_file |> Path.basename() |> Path.rootname()
  end

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
