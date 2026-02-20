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
    {"deploy_ex.install_github_action", "Installs GitHub Actions for automated infrastructure and deployment management"},
    {"deploy_ex.install_migration_script", "Installs migration scripts for running Ecto migrations in releases"},
    {"deploy_ex.release", "Builds releases for applications with detected changes"},
    {"deploy_ex.upload", "Uploads your release folder to Amazon S3"},
    {"deploy_ex.restart_app", "Restarts a specific application's systemd service"},
    {"deploy_ex.restart_machine", "Restarts EC2 instances for a specific application"},
    {"deploy_ex.remake", "Replaces and redeploys a specific application node"},
    {"deploy_ex.stop_app", "Stops a specific application's systemd service"},
    {"deploy_ex.start_app", "Starts a specific application's systemd service"},
    {"deploy_ex.ssh", "SSH into a specific app's remote node"},
    {"deploy_ex.ssh.authorize", "Add or remove SSH authorization to the internal network for specific IPs"},
    {"deploy_ex.download_file", "Downloads a file from a remote server using SCP"},
    {"deploy_ex.find_nodes", "Find EC2 instances by tags"},
    {"deploy_ex.select_node", "Select an EC2 instance and output its instance ID"},
    {"deploy_ex.list_app_release_history", "Lists the release history for a specific app from S3"},
    {"deploy_ex.list_available_releases", "Lists all available releases uploaded to the release bucket"},
    {"deploy_ex.view_current_release", "Shows the current (latest) release for a specific app from S3"},
    {"deploy_ex.instance.status", "Displays instance status for an application"},
    {"deploy_ex.instance.health", "Shows health status of EC2 instances"},
    {"deploy_ex.load_balancer.health", "Check load balancer health status for all instances"},

    # Autoscaling Commands
    {"deploy_ex.autoscale.status", "Displays autoscaling group status for an application"},
    {"deploy_ex.autoscale.scale", "Manually set desired capacity of an autoscaling group"},
    {"deploy_ex.autoscale.refresh", "Triggers an instance refresh to recreate autoscaling instances"},
    {"deploy_ex.autoscale.refresh_status", "Shows the status of instance refreshes for an autoscaling group"},

    # QA Node Commands
    {"deploy_ex.qa", "Overview of QA node commands and usage"},
    {"deploy_ex.qa.create", "Creates a new QA node with a specific SHA"},
    {"deploy_ex.qa.destroy", "Destroys a QA node"},
    {"deploy_ex.qa.list", "Lists all active QA nodes"},
    {"deploy_ex.qa.deploy", "Deploys a specific SHA to an existing QA node"},
    {"deploy_ex.qa.attach_lb", "Attaches a QA node to the app's load balancer"},
    {"deploy_ex.qa.detach_lb", "Detaches a QA node from the load balancer"},
    {"deploy_ex.qa.cleanup", "Cleans up orphaned QA nodes"},

    # Ansible Commands
    {"ansible.build", "Builds ansible files into your repository"},
    {"ansible.deploy", "Deploys to ansible hosts"},
    {"ansible.ping", "Pings all configured Ansible hosts"},
    {"ansible.rollback", "Rolls back an ansible host to a previous SHA"},
    {"ansible.setup", "Initial setup and configuration of Ansible hosts"},

    # Terraform Commands
    {"terraform.apply", "Applies terraform changes to provision AWS infrastructure"},
    {"terraform.build", "Builds/Updates terraform files or adds it to your project"},
    {"terraform.create_state_bucket", "Creates a bucket within S3 to host the terraform state file"},
    {"terraform.create_state_lock_table", "Creates a DynamoDB table for Terraform state locking"},
    {"terraform.create_ebs_snapshot", "Creates an EBS snapshot for a specified app"},
    {"terraform.delete_ebs_snapshot", "Deletes EBS snapshots for a specified app or by snapshot IDs"},
    {"terraform.drop", "Destroys all resources built by terraform"},
    {"terraform.drop_state_bucket", "Drops the S3 bucket used to host the Terraform state file"},
    {"terraform.drop_state_lock_table", "Drops the DynamoDB table used for Terraform state locking"},
    {"terraform.dump_database", "Dumps a database from RDS through a jump server"},
    {"terraform.generate_pem", "Extracts the PEM file from Terraform state and saves it locally"},
    {"terraform.init", "Initializes terraform in the project directory"},
    {"terraform.output", "Displays terraform output values"},
    {"terraform.plan", "Shows terraform's potential changes if you were to apply"},
    {"terraform.refresh", "Refreshes terraform state to sync with actual AWS resources"},
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
