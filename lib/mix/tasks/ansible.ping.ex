defmodule Mix.Tasks.Ansible.Ping do
  use Mix.Task

  @shortdoc "Pings all configured Ansible hosts"
  @moduledoc """
  Pings all hosts configured in the Ansible inventory file to verify connectivity.

  ## Example
  ```bash
  mix ansible.ping
  ```

  ## Options
  Any additional arguments passed will be forwarded directly to the ansible command.
  Common options include:
  - `-v` - Increase verbosity
  - `--limit hostname` - Only ping specific hosts
  """

  def run(args) do
    ansible_args = DeployEx.Ansible.parse_args(args)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      DeployExHelpers.check_file_exists!("./deploys/ansible/aws_ec2.yaml")

      DeployEx.Utils.run_command(
        "ansible -i aws_ec2.yaml #{ansible_args} all -m ping",
        "./deploys/ansible"
      )
    end
  end
end
