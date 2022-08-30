defmodule Mix.Tasks.DeployEx.FullSetup do
  use Mix.Task

  @shortdoc "Runs all the commands to setup terraform and ansible"
  @moduledoc """
  Runs all the commands to setup terraform and ansible.
  It also initializes AWS and pings the nodes to confirm they work
  """

  @commands ["terraform.build", "terraform.apply", "ansible.build", "ansible.ping"]

  def run(_args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      Enum.each(@commands, &Mix.shell().cmd(&1))
    end
  end
end


