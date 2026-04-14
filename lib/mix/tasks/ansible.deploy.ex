defmodule Mix.Tasks.Ansible.Deploy do
  use Mix.Task

  alias DeployEx.ReleaseUploader

  @ansible_default_path DeployEx.Config.ansible_folder_path()
  @playbook_timeout :timer.minutes(30)
  @playbook_max_concurrency 4

  @shortdoc "Deploys to ansible hosts"
  @moduledoc """
  Deploys each of your nodes with the latest release that can be found
  from S3.

  This will load your release onto each node and sets it up
  in a SystemD task.

  ## Example
  ```bash
  mix ansible.deploy
  mix ansible.deploy --only app1 --only app2
  mix ansible.deploy --except app3
  mix ansible.deploy --target-sha 2ac12b
  ```

  ## Options
  - `directory` - Directory containing ansible playbooks (default: #{@ansible_default_path})
  - `only` - Only deploy specified apps (can be used multiple times)
  - `except` - Skip deploying specified apps (can be used multiple times)
  - `copy-json-env-file` - Copy environment file and load into host environments
  - `only-local-release` - Only deploy if there's a local release available
  - `parallel` - Maximum number of concurrent ansible deploys (default: #{@playbook_max_concurrency})
  - `target-sha` - Deploy a specific release SHA instead of latest
  - `include-qa` - Include QA nodes in deploy (default: excluded)
  - `qa` - Target only QA nodes (excludes non-QA nodes)
  - `quiet` - Suppress output messages
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_valid_project(),
         :ok <- DeployEx.ToolInstaller.ensure_installed(:ansible) do
      opts = parse_args(args)

      opts = opts
        |> Keyword.put_new(:directory, @ansible_default_path)
        |> Keyword.put_new(:parallel, @playbook_max_concurrency)
        |> Keyword.put(:only, Keyword.get_values(opts, :only))
        |> Keyword.put(:except, Keyword.get_values(opts, :except))

      ansible_args = args
        |> DeployEx.Ansible.parse_args()
        |> then(fn
          "" -> []
          arg -> [arg]
        end)

      DeployExHelpers.check_file_exists!(Path.join(opts[:directory], "aws_ec2.yaml"))

      if opts[:target_sha] do
        Application.ensure_all_started(:hackney)
        Application.ensure_all_started(:telemetry)
        Application.ensure_all_started(:ex_aws)
      end

      opts = resolve_target_sha_prefix(opts)

      DeployEx.TUI.setup_no_tui(opts)

      playbooks = opts[:directory]
        |> Path.join("playbooks/*.yaml")
        |> Path.wildcard
        |> Enum.map(&strip_directory(&1, opts[:directory]))
        |> DeployExHelpers.filter_only_or_except(opts[:only], opts[:except])
        |> reject_playbook_without_local_release(opts[:only_local_release])
        |> reject_playbook_without_mix_exs_release

      if Enum.empty?(playbooks) do
        Mix.shell().info([:yellow, "Nothing to deploy"])
      else
        run_fn = fn host_playbook, line_callback ->
          command = host_playbook
            |> build_ansible_playbook_command(opts)
            |> Kernel.++(ansible_args)
            |> Enum.join(" ")

          DeployEx.Utils.run_command_streaming(command, opts[:directory], line_callback)
        end

        res = DeployEx.TUI.DeployProgress.run(playbooks, run_fn,
          max_concurrency: opts[:parallel],
          timeout: @playbook_timeout
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

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, l: :only_local_release, t: :target_sha],
      switches: [
        directory: :string,
        quiet: :boolean,
        only: :keep,
        except: :keep,
        copy_json_env_file: :string,
        parallel: :integer,
        only_local_release: :boolean,
        target_sha: :string,
        include_qa: :boolean,
        qa: :boolean,
        no_tui: :boolean
      ]
    )

    opts
  end

  def build_ansible_playbook_command(host_playbook, opts) do
    ["ansible-playbook", host_playbook]
      |> add_copy_env_file_flag(opts)
      |> add_target_release_sha(opts)
      |> add_release_prefix_vars(opts)
      |> exclude_qa_nodes(opts)
  end

  defp add_copy_env_file_flag(command_list, opts) do
    if opts[:copy_json_env_file] do
      json_file_path = case Path.type(opts[:copy_json_env_file]) do
        :absolute -> opts[:copy_json_env_file]
        :relative -> Path.join(File.cwd!(), opts[:copy_json_env_file])
      end

      DeployExHelpers.check_file_exists!(json_file_path)


      command_list ++ ["--extra-vars @#{json_file_path}"]
    else
      command_list
    end
  end

  defp add_target_release_sha(command_list, opts) do
    if opts[:target_sha] do
      command_list ++ ["--extra-vars \"target_release_sha=#{opts[:target_sha]}\""]
    else
      command_list
    end
  end

  defp add_release_prefix_vars(command_list, opts) do
    cond do
      opts[:resolved_release_prefix] === :qa ->
        command_list ++ ["--extra-vars \"release_prefix=qa release_state_prefix=release-state/qa\""]

      opts[:qa] === true ->
        command_list ++ ["--extra-vars \"release_prefix=qa release_state_prefix=release-state/qa\""]

      true ->
        command_list
    end
  end

  defp resolve_target_sha_prefix(opts) do
    case opts[:target_sha] do
      nil -> opts
      sha -> resolve_sha_location(opts, sha)
    end
  end

  defp resolve_sha_location(opts, sha) do
    region = DeployEx.Config.aws_region()
    bucket = DeployEx.Config.aws_release_bucket()

    case DeployEx.ReleaseUploader.AwsManager.get_releases(region, bucket) do
      {:ok, keys} ->
        cond do
          sha_in_prefix?(keys, sha, "qa/") ->
            unless opts[:quiet] do
              Mix.shell().info([:cyan, "Target SHA #{sha} found in qa prefix, deploying qa release"])
            end

            Keyword.put(opts, :resolved_release_prefix, :qa)

          sha_in_non_qa?(keys, sha) ->
            Keyword.put(opts, :resolved_release_prefix, :non_qa)

          true ->
            Mix.raise("Target SHA #{sha} not found in S3 bucket #{bucket} (searched both qa/ and non-qa prefixes)")
        end

      {:error, error} ->
        Mix.raise("Failed to verify target SHA in S3: #{ErrorMessage.to_string(error)}")
    end
  end

  defp sha_in_prefix?(keys, sha, prefix) do
    Enum.any?(keys, &(String.starts_with?(&1, prefix) and String.contains?(&1, sha)))
  end

  defp sha_in_non_qa?(keys, sha) do
    Enum.any?(keys, fn key ->
      not String.starts_with?(key, "qa/") and
        not String.starts_with?(key, "release-state/") and
        String.contains?(key, sha)
    end)
  end

  defp exclude_qa_nodes(command_list, opts) do
    has_custom_limit = Enum.any?(command_list, &String.contains?(&1, "--limit"))
    cond do
      opts[:qa] === true ->
        command_list ++ ["--limit", "'qa_true'"]
      opts[:include_qa] === true or has_custom_limit ->
        command_list
      true ->
        command_list ++ ["--limit", "'!qa_true'"]
    end
  end

  defp strip_directory(wildcard_result, directory) do
    String.replace(wildcard_result, String.trim_leading(directory, "./") <> "/", "")
  end

  defp reject_playbook_without_local_release(host_playbook_paths, true) do
    case ReleaseUploader.fetch_all_local_releases() do
      {:error, %ErrorMessage{code: :not_found}} -> []
      {:ok, local_releases} ->
        releases = local_release_app_names(local_releases)

        Enum.filter(host_playbook_paths, &has_local_release?(&1, releases))

      _ -> host_playbook_paths
    end
  end

  defp reject_playbook_without_local_release(host_playbook_paths, _) do
    host_playbook_paths
  end

  defp local_release_app_names(local_releases) do
    Enum.map(local_releases, fn local_release ->
      case local_release |> Path.basename |> String.split("-") do
        [_timestamp, _sha, app_name, _version] -> app_name

        [app_name, _version] -> app_name

        _ ->
          Mix.shell().error("Couldn't find app name from local release #{local_release}")
          []
      end
    end)
  end

  defp has_local_release?(host_playbook, releases) do
    Enum.any?(releases, &(Path.basename(host_playbook) =~ ~r/^#{&1}\.ya?ml/))
  end

  defp reject_playbook_without_mix_exs_release(host_playbooks) do
    case DeployExHelpers.fetch_mix_releases() do
      {:error, e} -> Mix.raise(e)

      {:ok, releases} ->
        release_names = releases |> Keyword.keys |> Enum.map(&to_string/1)

        Enum.filter(host_playbooks, fn playbook ->
          Enum.any?(release_names, &(playbook_release_name(playbook) =~ &1))
        end)
    end
  end

  defp playbook_release_name(playbook) do
    playbook |> Path.basename |> String.replace(~r/\.[^\.]*$/, "")
  end
end
