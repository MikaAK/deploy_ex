defmodule Mix.Tasks.DeployEx.FullSetup do
  use Mix.Task

  @shortdoc "Runs all the commands to setup terraform and ansible"
  @moduledoc """
  Runs all the commands to setup terraform and ansible.
  It also initializes AWS and pings the nodes to confirm they work
  """

  alias Mix.Tasks.Ansible
  alias Mix.Tasks.Terraform

  @commands [
    Terraform.Build,
    Terraform.Apply,
    Ansible.Build,
    Ansible.Ping
  ]

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      Enum.find_value(@commands, fn cmd_mod ->
        case cmd_mod.run(args) do
          :ok -> false
          {:error, _} = e -> e
        end
      end)
    end
  end
end


