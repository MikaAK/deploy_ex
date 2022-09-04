defmodule Mix.Tasks.Ansible.Deploy do
  use Mix.Task

  @ansible_default_path DeployEx.Config.ansible_folder_path()

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
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      opts = args
        |> parse_args
        |> Keyword.put_new(:directory, @ansible_default_path)

      DeployExHelpers.check_file_exists!(Path.join(opts[:directory], "hosts"))

      opts[:directory]
        |> Path.join("playbooks/*.yaml")
        |> Path.wildcard
        |> Enum.map(&strip_directory(&1, opts[:directory]))
        |> Enum.reject(&filtered_with_only_or_except?(&1, opts[:only], opts[:except]))
        |> Enum.each(fn host_playbook ->
          DeployExHelpers.run_command_with_input("ansible-playbook #{host_playbook}", opts[:directory])
        end)
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
        except: :keep
      ]
    )

    opts
  end
end


