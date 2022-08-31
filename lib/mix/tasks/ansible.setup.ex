defmodule Mix.Tasks.Ansible.Setup do
  use Mix.Task

  @ansible_default_path DeployEx.Config.ansible_folder_path()

  @shortdoc "Setups ansible hosts called once upon node creation"
  @moduledoc """
  Setups ansible hosts called once upon node creation
  """

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      opts = args
        |> parse_args
        |> Keyword.put_new(:directory, @ansible_default_path)

      DeployExHelpers.check_file_exists!(Path.join(opts[:directory], "hosts"))
      relative_directory = String.replace(Path.absname(opts[:directory]), "#{File.cwd!()}/", "")

      opts[:directory]
        |> Path.join("setup/*.yaml")
        |> Path.wildcard
        |> Enum.map(&Path.relative_to(&1, relative_directory))
        |> Enum.each(fn setup_file ->
          DeployExHelpers.run_command_with_input("ansible-playbook #{setup_file}", opts[:directory])
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

