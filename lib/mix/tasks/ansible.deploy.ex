defmodule Mix.Tasks.Ansible.Deploy do
  use Mix.Task

  @ansible_default_path DeployEx.Config.ansible_folder_path()

  @shortdoc "Deploys to ansible hosts"
  @moduledoc """
  Setups ansible hosts called once upon node creation
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
        |> Enum.each(fn host_playbook ->
          System.shell("ansible-playbook #{host_playbook}", cd: opts[:directory])
        end)
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean
      ]
    )

    opts
  end
end


