defmodule Mix.Tasks.DeployEx do
  use Mix.Task

  @shortdoc "Lists all available deploy_ex commands"
  @moduledoc """
  Lists all available deploy_ex commands and their descriptions.

  ## Example
  ```bash
  mix deploy_ex
  ```
  """

  @tasks [
    # DeployEx Commands
    {"deploy_ex.full_setup", "Performs complete infrastructure and application setup using Terraform and Ansible"},
    {"deploy_ex.full_drop", "Completely removes DeployEx configuration and files from the project"},
    {"deploy_ex.install_github_action", "Installs a GitHub Action for automated infrastructure and deployment management"},
    {"deploy_ex.install_migration_script", "Installs a migration script for managing database migrations during deployment"},
    {"deploy_ex.release", "Builds releases for applications with detected changes"},
    {"deploy_ex.upload", "Uploads your release folder to Amazon S3"},
    {"deploy_ex.restart_app", "Restarts a specific application's systemd service"},
    {"deploy_ex.restart_machine", "Restarts EC2 instances for a specific application"},
    {"deploy_ex.stop_app", "Stops a specific application's systemd service"},
    {"deploy_ex.ssh", "SSH into a specific app's remote node"},
    {"deploy_ex.ssh.authorize", "Add or remove SSH authorization to the internal network for specific IPs"},
    {"deploy_ex.download_file", "Downloads a file from a remote server using SCP"},

    # Ansible Commands
    {"ansible.build", "Builds ansible files into your repository"},
    {"ansible.deploy", "Deploys to ansible hosts"},
    {"ansible.ping", "Pings all configured Ansible hosts"},
    {"ansible.setup", "Initial setup and configuration of Ansible hosts"},

    # Terraform Commands
    {"terraform.apply", "Deploys to terraform resources using ansible"},
    {"terraform.build", "Builds/Updates terraform files or adds it to your project"},
    {"terraform.drop", "Destroys all resources built by terraform"},
    {"terraform.dump_database", "Dumps a database from RDS through a jump server"},
    {"terraform.generate_pem", "Extracts the PEM file and key name from the Terraform state"},
    {"terraform.init", "Runs terraform init"}
  ]

  def run(_) do
    Mix.shell().info([:green, "\nAvailable deploy_ex commands:\n"])

    Enum.each(@tasks, fn {task, description} ->
      Mix.shell().info([
        :yellow,
        "  #{String.pad_trailing(task, 35)}",
        :reset,
        description
      ])
    end)

    Mix.shell().info("\nRun any command with --help for more information.\n")
  end
end
