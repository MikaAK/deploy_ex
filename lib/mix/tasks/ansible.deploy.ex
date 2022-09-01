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
        |> Enum.map(&String.replace(&1, opts[:directory], ""))
        |> Enum.reject(&filtered_with_only_or_except?(&1, opts[:only], opts[:except]))
        |> Enum.each(fn host_playbook ->
          System.shell("ansible-playbook #{host_playbook}", cd: opts[:directory])
        end)
    end
  end

  defp filtered_with_only_or_except?(_playbook, [], []) do
    false
  end

  defp filtered_with_only_or_except?(playbook, only, []) do
    app_name = Path.basename(playbook)

    app_name in only
  end

  defp filtered_with_only_or_except?(playbook, [], except) do
    app_name = Path.basename(playbook)

    app_name not in except
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
        quiet: :boolean
      ]
    )

    opts
  end
end


