defmodule Mix.Tasks.Ansible.Deploy do
  use Mix.Task

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
  - `unchanged` - Only deploy unchanged releases (NOT SETUP)
  - `only` -  Specify specific apps to deploy too
  - `except` - Specify apps to not deploy to
  - `copy-json-env-file` - Copy env file and load into host environments
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
        |> Enum.reject(&filtered_with_only_or_except?(&1, opts[:only], opts[:except]))
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

  defp filtered_with_only_or_except?(_playbook, nil, nil) do
    false
  end

  defp filtered_with_only_or_except?(_playbook, [], []) do
    false
  end

  defp filtered_with_only_or_except?(playbook, only, []) do
    app_name = Path.basename(playbook)

    Enum.any?(only, &(&1 =~ app_name))
  end

  defp filtered_with_only_or_except?(playbook, [], except) do
    app_name = Path.basename(playbook)

    app_name not in except
  end

  defp filtered_with_only_or_except?(playbook, nil, except) when is_binary(except)  do
    app_name = Path.basename(playbook)

    not Enum.any?(except, &(&1 =~ app_name))
  end

  defp filtered_with_only_or_except?(playbook, only, nil) when is_binary(only)  do
    app_name = Path.basename(playbook)

    not (app_name =~ only)
  end

  defp filtered_with_only_or_except?(_, _, _)  do
    raise to_string(IO.ANSI.format([
      :red,
      "Cannot specify both only and except arguments"
    ]))
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory],
      switches: [
        directory: :string,
        quiet: :boolean,
        only: :keep,
        except: :keep,
        copy_json_env_file: :string,
        parallel: :integer
      ]
    )

    opts
  end
end


