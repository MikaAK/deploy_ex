defmodule Mix.Tasks.Ansible.Ping do
  use Mix.Task

  @shortdoc "Pings ansible hosts define in hosts file"
  @moduledoc """
  Pings ansible hosts define in hosts file
  """

  def run(args) do
    ansible_args = DeployExHelpers.to_ansible_args(args)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      DeployExHelpers.check_file_exists!("./deploys/ansible/aws_ec2.yaml")

      DeployExHelpers.run_command(
        "ansible -i aws_ec2.yaml #{ansible_args} all -m ping",
        "./deploys/ansible"
      )
    end
  end
end
