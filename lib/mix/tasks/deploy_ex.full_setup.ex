defmodule Mix.Tasks.DeployEx.FullSetup do
  use Mix.Task

  @shortdoc "Runs all the commands to setup terraform and ansible"
  @moduledoc """
  Runs all the commands to setup terraform and ansible.
  It also initializes AWS and pings the nodes to confirm they work
  """

  alias Mix.Tasks.Ansible
  alias Mix.Tasks.Terraform

  @pre_setup_commands [
    Terraform.Build,
    Terraform.Apply,
    Ansible.Build
  ]

  @post_setup_comands [
    Ansible.Ping,
    Ansible.Setup
  ]

  @time_between_pre_post :timer.seconds(10)

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      case run_commands(@pre_setup_commands, args) do
        false ->
          Mix.shell().info([
            :green, "* sleeping for ", :reset,
            @time_between_pre_post |> div(1000) |> to_string,
            :green, " seconds to allow setup"])

          Process.sleep(@time_between_pre_post)

          run_commands(@post_setup_comands, args)
        e -> e
      end
    end
  end

  defp run_commands(commands, args) do
    Enum.find_value(commands, fn cmd_mod ->
      case cmd_mod.run(args) do
        :ok -> false
        {:error, _} = e -> e
      end
    end)
  end
end


