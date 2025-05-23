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
  - `target-sha` - Maximum number of concurrent ansible deploys (default: #{@playbook_max_concurrency})
  - `quiet` - Suppress output messages
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
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

      res = opts[:directory]
        |> Path.join("playbooks/*.yaml")
        |> Path.wildcard
        |> Enum.map(&strip_directory(&1, opts[:directory]))
        |> DeployExHelpers.filter_only_or_except(opts[:only], opts[:except])
        |> reject_playbook_without_local_release(opts[:only_local_release])
        |> reject_playbook_without_mix_exs_release
        |> Task.async_stream(fn host_playbook ->
          host_playbook
            |> build_ansible_playbook_command(opts)
            |> Kernel.++(ansible_args)
            |> Enum.join(" ")
            |> DeployEx.Utils.run_command(opts[:directory])
        end, max_concurrency: opts[:parallel], timeout: @playbook_timeout)
        |> DeployEx.Utils.reduce_status_tuples

      case res do
        {:ok, []} -> Mix.shell().info([:yellow, "Nothing to deploy"])

        {:error, [h | tail]} ->
          Enum.each(tail, &Mix.shell().error(to_string(&1)))

          Mix.raise(to_string(h))

        _ -> :ok
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
        target_sha: :string
      ]
    )

    opts
  end

  def build_ansible_playbook_command(host_playbook, opts) do
    ["ansible-playbook", host_playbook]
      |> add_copy_env_file_flag(opts)
      |> add_target_release_sha(opts)
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
