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
    {"deploy_ex.remake", "Replaces and redeploys a specific application node"},
    {"deploy_ex.stop_app", "Stops a specific application's systemd service"},
    {"deploy_ex.start_app", "Starts a specific application's systemd service"},
    {"deploy_ex.ssh", "SSH into a specific app's remote node"},
    {"deploy_ex.ssh.authorize", "Add or remove ssh authorization to the internal network for specific IPs"},
    {"deploy_ex.download_file", "Downloads a file from a remote server using SCP"},
    {"deploy_ex.list_app_release_history", "Lists the latest releases for a specific app via SSH"},
    {"deploy_ex.list_available_releases", "Lists all available releases uploaded to the release bucket"},
    {"deploy_ex.view_current_release", "Shows the current (latest) release for a specific app via SSH"},
    {"deploy_ex.test", "Runs mix.release for apps that have changed"},

    # Autoscaling Commands
    {"deploy_ex.autoscale.status", "Displays autoscaling group status (instance count, limits, policies)"},
    {"deploy_ex.autoscale.scale", "Manually sets desired capacity of an autoscaling group"},

    # Ansible Commands
    {"ansible.build", "Builds ansible files into your repository"},
    {"ansible.deploy", "Deploys to ansible hosts"},
    {"ansible.ping", "Pings all configured Ansible hosts"},
    {"ansible.rollback", "Rollsback an ansible host to a previous sha"},
    {"ansible.setup", "Initial setup and configuration of Ansible hosts"},

    # Terraform Commands
    {"terraform.apply", "Deploys to terraform resources using ansible"},
    {"terraform.build", "Builds/Updates terraform files or adds it to your project"},
    {"terraform.create_state_bucket", "Creates a bucket within S3 to host the terraform state file"},
    {"terraform.drop", "Destroys all resources built by terraform"},
    {"terraform.drop_state_bucket", "Drops the S3 bucket used to host the Terraform state file"},
    {"terraform.dump_database", "Dumps a database from RDS through a jump server"},
    {"terraform.generate_pem", "Extracts the PEM file and key name from the Terraform state"},
    {"terraform.init", "Runs terraform init"},
    {"terraform.output", "Gets terraform output"},
    {"terraform.plan", "Shows terraforms potential changes if you were to apply"},
    {"terraform.refresh", "Refreshes terraform and fetches new public ips for example if they've changed"},
    {"terraform.replace", "Runs terraform replace with a node"},
    {"terraform.restore_database", "Restores a database dump to either RDS or local PostgreSQL"},
    {"terraform.show_password", "Shows passwords for databases in the cluster"}
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
