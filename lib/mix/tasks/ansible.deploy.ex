defmodule Mix.Tasks.Ansible.Deploy do
  use Mix.Task

  alias DeployEx.ReleaseUploader

  @ansible_default_path DeployEx.Config.ansible_folder_path()
  @playbook_timeout :timer.minutes(30)
  @playbook_max_concurrency 4

  @shortdoc "Deploys to ansible hosts"
  @moduledoc """
  Deploys each of your nodes with the latest release that can be found
  from S3

  This will load your release onto each node and sets it up
  in a SystemD task

  ### Options
  - `directory` - Directory for the playbooks
  - `only` -  Specify specific apps to deploy too
  - `except` - Specify apps to not deploy to
  - `copy-json-env-file` - Copy env file and load into host environments
  - `only-local-release` - Only deploy if there's a local release
  - `parallel` - Set max amount of ansible deploys running at once
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      opts = args
        |> parse_args
        |> Keyword.put_new(:directory, @ansible_default_path)
        |> Keyword.put_new(:parallel, @playbook_max_concurrency)

      DeployExHelpers.check_file_exists!(Path.join(opts[:directory], "hosts"))

      res = opts[:directory]
        |> Path.join("playbooks/*.yaml")
        |> Path.wildcard
        |> Enum.map(&strip_directory(&1, opts[:directory]))
        |> DeployExHelpers.filter_only_or_except(opts[:only], opts[:except])
        |> reject_playbook_without_local_release(opts[:only_local_release])
        |> Task.async_stream(fn host_playbook ->
          host_playbook
            |> run_ansible_playbook_command(opts)
            |> DeployExHelpers.run_command_with_input(opts[:directory])
        end, max_concurrency: opts[:parallel], timeout: @playbook_timeout)
        |> DeployEx.Utils.reduce_status_tuples

      with {:error, [h | tail]} <- res do
        Enum.each(tail, &Mix.shell().error(to_string(&1)))

        Mix.raise(to_string(h))
      end
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, l: :only_local_release],
      switches: [
        directory: :string,
        quiet: :boolean,
        only: :keep,
        except: :keep,
        copy_json_env_file: :string,
        parallel: :integer,
        only_local_release: :boolean
      ]
    )

    opts
  end

  def run_ansible_playbook_command(host_playbook, opts) do
    if opts[:copy_json_env_file] do
      json_file_path = case Path.type(opts[:copy_json_env_file]) do
        :absolute -> opts[:copy_json_env_file]
        :relative -> Path.join(File.cwd!(), opts[:copy_json_env_file])
      end

      DeployExHelpers.check_file_exists!(json_file_path)


      "ansible-playbook #{host_playbook} --extra-vars @#{json_file_path}"
    else
      "ansible-playbook #{host_playbook}"
    end
  end

  defp strip_directory(wildcard_result, directory) do
    String.replace(wildcard_result, String.trim_leading(directory, "./") <> "/", "")
  end

  defp reject_playbook_without_local_release(host_playbook_paths, true) do
    case ReleaseUploader.fetch_all_local_releases() |> IO.inspect  do
      {:error, %ErrorMessage{code: :not_found}} -> []
      {:ok, local_releases} ->
        releases = local_release_app_names(local_releases)

        Enum.filter(host_playbook_paths, &has_local_release?(&1, releases))

      _ -> host_playbook_paths
    end
  end

  defp reject_playbook_without_local_release(host_playbook_paths, false) do
    host_playbook_paths
  end

  defp local_release_app_names(local_releases) do
    Enum.map(local_releases, fn local_release ->
      case local_release |> Path.basename |> String.split("-") do
        [_timestamp, _sha, app_name, _version] -> app_name

        _ ->
          Mix.shell().error("Couldn't find app name from local release #{local_release}")
          []
      end
    end)
  end

  defp has_local_release?(host_playbook, releases) do
    Enum.any?(releases, &(Path.basename(host_playbook) =~ ~r/^#{&1}\.yml/))
  end
end
