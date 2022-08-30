defmodule Mix.Tasks.Ansible.Ping do
  use Mix.Task

  @shortdoc "Pings ansible hosts define in hosts file"
  @moduledoc """
  Pings ansible hosts define in hosts file
  """

  def run(_args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      DeployExHelpers.check_file_exists!("./deploys/ansible/hosts")

      DeployExHelpers.run_command_with_input("ansible -i hosts all -m ping", "./deploys/ansible")
    end
  end
end

