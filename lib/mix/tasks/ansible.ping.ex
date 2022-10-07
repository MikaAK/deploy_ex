defmodule Mix.Tasks.Ansible.Ping do
  use Mix.Task

  @shortdoc "Pings ansible hosts define in hosts file"
  @moduledoc """
  Pings ansible hosts define in hosts file
  """

  def run(args) do
    group_name = args |> Enum.reject(&(&1 =~ ~r/^--?/)) |> List.first
    group_name = (group_name && "group_#{group_name}") || "all"

    with :ok <- DeployExHelpers.check_in_umbrella() do
      DeployExHelpers.check_file_exists!("./deploys/ansible/aws_ec2.yaml")

      DeployExHelpers.run_command_with_input("ansible -i aws_ec2.yaml #{group_name} -m ping", "./deploys/ansible")
    end
  end
end

