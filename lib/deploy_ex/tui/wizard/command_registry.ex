defmodule DeployEx.TUI.Wizard.CommandRegistry do
  @moduledoc false

  @type choices_fn :: (-> list(String.t()))

  @type input_def :: %{
    key: atom(),
    label: String.t(),
    type: :string | :boolean | :select | :integer,
    required: boolean(),
    positional: boolean(),
    default: term(),
    description: String.t(),
    choices_fn: choices_fn() | nil
  }

  @type command_def :: %{
    task: String.t(),
    module: module(),
    category: String.t(),
    inputs: list(input_def())
  }

  def fetch_app_names do
    case DeployExHelpers.fetch_mix_release_names() do
      {:ok, names} -> Enum.map(names, &to_string/1)
      _ -> []
    end
  end

  defp input(key, label, type, opts \\ []) do
    %{
      key: key,
      label: label,
      type: type,
      required: Keyword.get(opts, :required, false),
      positional: Keyword.get(opts, :positional, false),
      default: Keyword.get(opts, :default, nil),
      description: Keyword.get(opts, :description, ""),
      choices_fn: Keyword.get(opts, :choices_fn, nil)
    }
  end

  defp build_commands do
    [
    # ─── DeployEx ──────────────────────────────────────────────────────
    %{
      task: "deploy_ex.full_setup",
      module: Mix.Tasks.DeployEx.FullSetup,
      category: "DeployEx",
      inputs: [
        input(:skip_setup, "Skip setup wait", :boolean, description: "Skip waiting period between infra creation and setup")
      ]
    },
    %{
      task: "deploy_ex.full_drop",
      module: Mix.Tasks.DeployEx.FullDrop,
      category: "DeployEx",
      inputs: []
    },
    %{
      task: "deploy_ex.install_github_action",
      module: Mix.Tasks.DeployEx.InstallGithubAction,
      category: "DeployEx",
      inputs: [
        input(:force, "Force overwrite", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:pem_directory, "Use pem directory", :boolean, description: "Treat PEM as directory path"),
        input(:pem, "PEM file", :string, description: "Path to PEM key")
      ]
    },
    %{
      task: "deploy_ex.install_migration_script",
      module: Mix.Tasks.DeployEx.InstallMigrationScript,
      category: "DeployEx",
      inputs: [
        input(:force, "Force overwrite", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:directory, "Directory", :string, description: "Output directory")
      ]
    },
    %{
      task: "deploy_ex.export_priv",
      module: Mix.Tasks.DeployEx.ExportPriv,
      category: "DeployEx",
      inputs: [
        input(:force, "Force overwrite", :boolean, description: "Overwrite files that already exist in ./deploys/"),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.upgrade_priv",
      module: Mix.Tasks.DeployEx.UpgradePriv,
      category: "DeployEx",
      inputs: [
        input(:ai_review, "AI review", :boolean, description: "LLM reviews diffs and proposes a plan; you confirm per file"),
        input(:llm_merge, "LLM merge", :boolean, description: "LLM applies all changes autonomously")
      ]
    },
    %{
      task: "deploy_ex.release",
      module: Mix.Tasks.DeployEx.Release,
      category: "DeployEx",
      inputs: [
        input(:force, "Force rebuild", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:recompile, "Recompile", :boolean, description: "Force recompilation"),
        input(:aws_region, "AWS region", :string),
        input(:aws_release_bucket, "AWS release bucket", :string),
        input(:only, "Only app(s)", :string, description: "Comma-separated app names to release"),
        input(:except, "Except app(s)", :string, description: "Comma-separated app names to skip"),
        input(:all, "All apps", :boolean, description: "Release every configured app")
      ]
    },
    %{
      task: "deploy_ex.upload",
      module: Mix.Tasks.DeployEx.Upload,
      category: "DeployEx",
      inputs: [
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:aws_region, "AWS region", :string, description: "Override AWS region"),
        input(:aws_release_bucket, "AWS release bucket", :string),
        input(:parallel, "Max concurrency", :integer),
        input(:qa, "QA upload", :boolean, description: "Upload to the QA prefix")
      ]
    },
    %{
      task: "deploy_ex.restart_app",
      module: Mix.Tasks.DeployEx.RestartApp,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:directory, "Directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:pem, "PEM file", :string),
        input(:resource_group, "Resource group", :string)
      ]
    },
    %{
      task: "deploy_ex.restart_machine",
      module: Mix.Tasks.DeployEx.RestartMachine,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:aws_region, "AWS region", :string),
        input(:resource_group, "Resource group", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.remake",
      module: Mix.Tasks.DeployEx.Remake,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:no_deploy, "Skip deploy", :boolean, description: "Skip Ansible deploy after replace + setup")
      ]
    },
    %{
      task: "deploy_ex.stop_app",
      module: Mix.Tasks.DeployEx.StopApp,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:directory, "Directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:pem, "PEM file", :string),
        input(:resource_group, "Resource group", :string)
      ]
    },
    %{
      task: "deploy_ex.start_app",
      module: Mix.Tasks.DeployEx.StartApp,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:directory, "Directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:pem, "PEM file", :string),
        input(:resource_group, "Resource group", :string)
      ]
    },
    %{
      task: "deploy_ex.ssh",
      module: Mix.Tasks.DeployEx.Ssh,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:directory, "Directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:short, "Short output", :boolean, description: "Print SSH command only"),
        input(:root, "Root access", :boolean),
        input(:log, "View logs", :boolean),
        input(:log_count, "Log line count", :integer),
        input(:log_user, "Log user", :string),
        input(:all, "All instances", :boolean),
        input(:iex, "IEx remote", :boolean),
        input(:pem, "PEM file", :string),
        input(:resource_group, "Resource group", :string),
        input(:index, "Instance index", :integer, description: "Connect to a specific instance (0-based)"),
        input(:list, "List instances", :boolean),
        input(:qa, "QA only", :boolean),
        input(:instance_id, "Instance ID", :string, description: "Specific instance ID")
      ]
    },
    %{
      task: "deploy_ex.ssh.authorize",
      module: Mix.Tasks.DeployEx.Ssh.Authorize,
      category: "DeployEx",
      inputs: [
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:remove, "Remove rule", :boolean, description: "Remove the authorized rule instead of adding"),
        input(:ip, "IP address", :string),
        input(:region, "AWS region", :string),
        input(:security_group_id, "Security group ID", :string)
      ]
    },
    %{
      task: "deploy_ex.download_file",
      module: Mix.Tasks.DeployEx.DownloadFile,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:remote_path, "Remote path", :string,
          required: true,
          positional: true,
          description: "Path of the file on the remote host"
        ),
        input(:local_path, "Local path", :string,
          positional: true,
          description: "Optional local destination path"
        ),
        input(:directory, "Directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:resource_group, "Resource group", :string),
        input(:pem, "PEM file", :string)
      ]
    },
    %{
      task: "deploy_ex.find_nodes",
      module: Mix.Tasks.DeployEx.FindNodes,
      category: "DeployEx",
      inputs: [
        input(:tag, "Tag filter", :string, description: "Repeatable tag filter (Key=Value)"),
        input(:setup_complete, "Setup complete", :boolean),
        input(:setup_incomplete, "Setup incomplete", :boolean),
        input(:format, "Output format", :string),
        input(:region, "AWS region", :string),
        input(:resource_group, "Resource group", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.select_node",
      module: Mix.Tasks.DeployEx.SelectNode,
      category: "DeployEx",
      inputs: [
        input(:short, "Short output", :boolean),
        input(:qa, "QA only", :boolean),
        input(:region, "AWS region", :string),
        input(:resource_group, "Resource group", :string)
      ]
    },
    %{
      task: "deploy_ex.list_app_release_history",
      module: Mix.Tasks.DeployEx.ListAppReleaseHistory,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:limit, "Limit", :integer),
        input(:region, "AWS region", :string),
        input(:bucket, "S3 bucket", :string)
      ]
    },
    %{
      task: "deploy_ex.list_available_releases",
      module: Mix.Tasks.DeployEx.ListAvailableReleases,
      category: "DeployEx",
      inputs: [
        input(:app, "App filter", :string, description: "Filter by app name")
      ]
    },
    %{
      task: "deploy_ex.view_current_release",
      module: Mix.Tasks.DeployEx.ViewCurrentRelease,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:region, "AWS region", :string),
        input(:bucket, "S3 bucket", :string)
      ]
    },
    %{
      task: "deploy_ex.instance.status",
      module: Mix.Tasks.DeployEx.Instance.Status,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:environment, "Environment", :string)
      ]
    },
    %{
      task: "deploy_ex.instance.health",
      module: Mix.Tasks.DeployEx.Instance.Health,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:qa, "QA only", :boolean),
        input(:all, "All instances", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_balancer.health",
      module: Mix.Tasks.DeployEx.LoadBalancer.Health,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:qa, "QA only", :boolean),
        input(:watch, "Watch (auto-refresh)", :boolean),
        input(:json, "JSON output", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.grafana.install_dashboard",
      module: Mix.Tasks.DeployEx.Grafana.InstallDashboard,
      category: "DeployEx",
      inputs: [
        input(:file, "Dashboard JSON file", :string, description: "Path to a local dashboard JSON file"),
        input(:id, "Grafana.com dashboard ID", :integer, description: "Downloads latest revision from grafana.com"),
        input(:grafana_ip, "Grafana IP", :string, description: "Manual Grafana node IP (skips EC2 discovery)"),
        input(:grafana_port, "Grafana port", :integer, description: "Grafana port (default: 80)"),
        input(:user, "Grafana user", :string, description: "Grafana admin username (default: admin)"),
        input(:password, "Grafana password", :string, description: "Grafana admin password"),
        input(:resource_group, "Resource group", :string, description: "AWS resource group for node discovery"),
        input(:pem, "PEM file", :string, description: "Path to PEM file for SSH tunnel"),
        input(:quiet, "Quiet", :boolean)
      ]
    },

    # ─── Autoscaling ───────────────────────────────────────────────────
    %{
      task: "deploy_ex.autoscale.status",
      module: Mix.Tasks.DeployEx.Autoscale.Status,
      category: "Autoscaling",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:environment, "Environment", :string)
      ]
    },
    %{
      task: "deploy_ex.autoscale.scale",
      module: Mix.Tasks.DeployEx.Autoscale.Scale,
      category: "Autoscaling",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:desired_capacity, "Desired capacity", :integer,
          required: true,
          positional: true,
          description: "Number of instances to scale to"
        ),
        input(:environment, "Environment", :string),
        input(:update_limits, "Update min/max limits", :boolean)
      ]
    },
    %{
      task: "deploy_ex.autoscale.refresh",
      module: Mix.Tasks.DeployEx.Autoscale.Refresh,
      category: "Autoscaling",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:environment, "Environment", :string),
        input(:strategy, "Strategy", :string, description: "Refresh strategy"),
        input(:availability, "Availability", :string),
        input(:min_healthy_percentage, "Min healthy %", :integer),
        input(:max_healthy_percentage, "Max healthy %", :integer),
        input(:instance_warmup, "Instance warmup", :integer),
        input(:wait, "Wait for completion", :boolean),
        input(:skip_matching, "Skip matching", :boolean)
      ]
    },
    %{
      task: "deploy_ex.autoscale.refresh_status",
      module: Mix.Tasks.DeployEx.Autoscale.RefreshStatus,
      category: "Autoscaling",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:environment, "Environment", :string),
        input(:all, "All refreshes", :boolean, description: "Show all historical refreshes")
      ]
    },

    # ─── QA ────────────────────────────────────────────────────────────
    %{
      task: "deploy_ex.qa.create",
      module: Mix.Tasks.DeployEx.Qa.Create,
      category: "QA",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:sha, "Git SHA", :string, description: "Target git SHA to deploy"),
        input(:tag, "Tag", :string, description: "Custom label used in the instance name (replaces the short SHA)"),
        input(:instance_type, "Instance type", :string, default: "t3.small"),
        input(:skip_setup, "Skip setup", :boolean),
        input(:skip_deploy, "Skip deploy", :boolean),
        input(:skip_ami, "Skip AMI", :boolean),
        input(:skip_host_rewrite, "Skip host rewrite", :boolean),
        input(:use_ami, "Use AMI", :boolean, description: "Boot from the app's pre-baked AMI (skips setup)"),
        input(:attach_lb, "Attach to load balancer", :boolean),
        input(:public_ip_cert, "Public IP cert", :boolean, description: "Issue Let's Encrypt cert for the public IP"),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:aws_region, "AWS region", :string),
        input(:aws_release_bucket, "AWS release bucket", :string),
        input(:wait_for_build, "Wait for build", :boolean, description: "Wait for the GitHub Actions build to finish before creating"),
        input(:build_workflow, "Build workflow", :string, description: "GitHub Actions workflow file (e.g. release.yml)"),
        input(:build_job, "Build job", :string, description: "GitHub Actions job name to wait on"),
        input(:build_timeout, "Build timeout (s)", :integer, description: "Timeout in seconds when waiting for the build")
      ]
    },
    %{
      task: "deploy_ex.qa.destroy",
      module: Mix.Tasks.DeployEx.Qa.Destroy,
      category: "QA",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:instance_id, "Instance ID", :string, description: "Destroy a specific instance by ID"),
        input(:all, "All QA nodes", :boolean, description: "Destroy every QA node across all apps"),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.qa.list",
      module: Mix.Tasks.DeployEx.Qa.List,
      category: "QA",
      inputs: [
        input(:app, "App filter", :string, description: "Filter by app name"),
        input(:json, "JSON output", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.qa.deploy",
      module: Mix.Tasks.DeployEx.Qa.Deploy,
      category: "QA",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:sha, "Git SHA", :string),
        input(:instance_id, "Instance ID", :string, description: "Target a specific QA instance when multiple exist"),
        input(:public_ip_cert, "Public IP cert", :boolean, description: "Toggle public-IP LE cert mode"),
        input(:quiet, "Quiet", :boolean),
        input(:aws_region, "AWS region", :string),
        input(:aws_release_bucket, "AWS release bucket", :string)
      ]
    },
    %{
      task: "deploy_ex.qa.attach_lb",
      module: Mix.Tasks.DeployEx.Qa.AttachLb,
      category: "QA",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:instance_id, "Instance ID", :string),
        input(:target_group, "Target group ARN", :string, description: "Specific target group ARN (default: auto-discover)"),
        input(:port, "Port", :integer, description: "Port to register (default: 4000)"),
        input(:wait, "Wait for healthy", :boolean, description: "Wait for health check to pass"),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.qa.detach_lb",
      module: Mix.Tasks.DeployEx.Qa.DetachLb,
      category: "QA",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:instance_id, "Instance ID", :string),
        input(:target_group, "Target group ARN", :string, description: "Specific target group ARN (default: all attached)"),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.qa.cleanup",
      module: Mix.Tasks.DeployEx.Qa.Cleanup,
      category: "QA",
      inputs: [
        input(:dry_run, "Dry run", :boolean, description: "Show what would be cleaned without taking action"),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },

    # ─── Ansible ───────────────────────────────────────────────────────
    %{
      task: "ansible.build",
      module: Mix.Tasks.Ansible.Build,
      category: "Ansible",
      inputs: [
        input(:new_only, "New only", :boolean, description: "Only render new files; skip existing"),
        input(:force, "Force overwrite", :boolean),
        input(:host_only, "Host only", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:directory, "Ansible directory", :string),
        input(:terraform_directory, "Terraform directory", :string),
        input(:auto_pull_aws, "Auto pull from AWS", :boolean),
        input(:aws_release_bucket, "AWS release bucket", :string),
        input(:no_logging, "Disable logging", :boolean),
        input(:no_loki, "Disable Loki", :boolean),
        input(:no_sentry, "Disable Sentry", :boolean),
        input(:no_grafana, "Disable Grafana", :boolean),
        input(:no_prometheus, "Disable Prometheus", :boolean)
      ]
    },
    %{
      task: "ansible.deploy",
      module: Mix.Tasks.Ansible.Deploy,
      category: "Ansible",
      inputs: [
        input(:directory, "Ansible directory", :string),
        input(:quiet, "Quiet", :boolean),
        input(:only, "Only app(s)", :string, description: "Comma-separated app names to deploy"),
        input(:except, "Except app(s)", :string, description: "Comma-separated app names to skip"),
        input(:copy_json_env_file, "Copy JSON env file", :string, description: "Path to env JSON file to upload"),
        input(:parallel, "Max concurrency", :integer, default: 4),
        input(:only_local_release, "Only local releases", :boolean),
        input(:target_sha, "Target SHA", :string, description: "Deploy specific release SHA"),
        input(:include_qa, "Include QA nodes", :boolean),
        input(:qa, "QA nodes only", :boolean)
      ]
    },
    %{
      task: "ansible.ping",
      module: Mix.Tasks.Ansible.Ping,
      category: "Ansible",
      inputs: [
        input(:inventory, "Inventory file", :string),
        input(:limit, "Limit hosts", :string, description: "Restrict to a specific host or group"),
        input(:extra_vars, "Extra vars", :string, description: "Repeatable extra-var argument forwarded to ansible")
      ]
    },
    %{
      task: "ansible.rollback",
      module: Mix.Tasks.Ansible.Rollback,
      category: "Ansible",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:directory, "Ansible directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:select, "Select", :boolean, description: "Interactively pick the SHA to roll back to")
      ]
    },
    %{
      task: "ansible.setup",
      module: Mix.Tasks.Ansible.Setup,
      category: "Ansible",
      inputs: [
        input(:directory, "Ansible directory", :string),
        input(:only, "Only app(s)", :string),
        input(:except, "Except app(s)", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:parallel, "Max concurrency", :integer),
        input(:include_qa, "Include QA nodes", :boolean)
      ]
    },

    # ─── Terraform ─────────────────────────────────────────────────────
    %{
      task: "terraform.apply",
      module: Mix.Tasks.Terraform.Apply,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:auto_approve, "Auto-approve", :boolean)
      ]
    },
    %{
      task: "terraform.build",
      module: Mix.Tasks.Terraform.Build,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:force, "Force overwrite", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:verbose, "Verbose", :boolean),
        input(:aws_region, "AWS region", :string),
        input(:env, "Environment", :string),
        input(:no_database, "Disable database", :boolean),
        input(:no_logging, "Disable logging", :boolean),
        input(:no_loki, "Disable Loki", :boolean),
        input(:no_sentry, "Disable Sentry", :boolean),
        input(:no_grafana, "Disable Grafana", :boolean),
        input(:no_redis, "Disable Redis", :boolean),
        input(:no_prometheus, "Disable Prometheus", :boolean)
      ]
    },
    %{
      task: "terraform.create_state_bucket",
      module: Mix.Tasks.Terraform.CreateStateBucket,
      category: "Terraform",
      inputs: []
    },
    %{
      task: "terraform.create_state_lock_table",
      module: Mix.Tasks.Terraform.CreateStateLockTable,
      category: "Terraform",
      inputs: []
    },
    %{
      task: "terraform.create_ebs_snapshot",
      module: Mix.Tasks.Terraform.CreateEbsSnapshot,
      category: "Terraform",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:description, "Description", :string),
        input(:aws_region, "AWS region", :string),
        input(:resource_group, "Resource group", :string),
        input(:include_root, "Include root volume", :boolean)
      ]
    },
    %{
      task: "terraform.delete_ebs_snapshot",
      module: Mix.Tasks.Terraform.DeleteEbsSnapshot,
      category: "Terraform",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:snapshot_ids, "Snapshot IDs", :string, description: "Comma-separated snapshot IDs"),
        input(:all, "All snapshots", :boolean),
        input(:force, "Force", :boolean),
        input(:aws_region, "AWS region", :string),
        input(:resource_group, "Resource group", :string),
        input(:max_age_days, "Max age (days)", :integer)
      ]
    },
    %{
      task: "terraform.drop",
      module: Mix.Tasks.Terraform.Drop,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:auto_approve, "Auto-approve", :boolean)
      ]
    },
    %{
      task: "terraform.drop_state_bucket",
      module: Mix.Tasks.Terraform.DropStateBucket,
      category: "Terraform",
      inputs: []
    },
    %{
      task: "terraform.drop_state_lock_table",
      module: Mix.Tasks.Terraform.DropStateLockTable,
      category: "Terraform",
      inputs: []
    },
    %{
      task: "terraform.dump_database",
      module: Mix.Tasks.Terraform.DumpDatabase,
      category: "Terraform",
      inputs: [
        input(:database_name, "Database name", :string,
          positional: true,
          description: "Database to dump (interactive picker if omitted)"
        ),
        input(:directory, "Terraform directory", :string),
        input(:output, "Output file", :string),
        input(:schema_only, "Schema only", :boolean),
        input(:local_port, "Local port", :integer),
        input(:identifier, "DB identifier", :string),
        input(:format, "Format", :string),
        input(:resource_group, "Resource group", :string),
        input(:pem, "PEM file", :string),
        input(:backend, "Backend", :string),
        input(:bucket, "S3 bucket", :string),
        input(:region, "AWS region", :string)
      ]
    },
    %{
      task: "terraform.generate_pem",
      module: Mix.Tasks.Terraform.GeneratePem,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:output_file, "Output file", :string),
        input(:backend, "Backend", :string),
        input(:bucket, "S3 bucket", :string),
        input(:region, "AWS region", :string)
      ]
    },
    %{
      task: "terraform.init",
      module: Mix.Tasks.Terraform.Init,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:upgrade, "Upgrade providers", :boolean)
      ]
    },
    %{
      task: "terraform.output",
      module: Mix.Tasks.Terraform.Output,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:short, "Short output", :boolean)
      ]
    },
    %{
      task: "terraform.plan",
      module: Mix.Tasks.Terraform.Plan,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.refresh",
      module: Mix.Tasks.Terraform.Refresh,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.replace",
      module: Mix.Tasks.Terraform.Replace,
      category: "Terraform",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:string, "Match string", :string, description: "Match a specific resource address fragment"),
        input(:directory, "Terraform directory", :string),
        input(:node, "Node index", :integer),
        input(:all, "All matches", :boolean),
        input(:auto_approve, "Auto-approve", :boolean),
        input(:resource_group, "Resource group", :string),
        input(:region, "AWS region", :string)
      ]
    },
    %{
      task: "terraform.restore_database",
      module: Mix.Tasks.Terraform.RestoreDatabase,
      category: "Terraform",
      inputs: [
        input(:database_name, "Database name", :string,
          required: true,
          positional: true
        ),
        input(:dump_file, "Dump file", :string,
          required: true,
          positional: true
        ),
        input(:directory, "Terraform directory", :string),
        input(:local, "Local restore", :boolean),
        input(:schema_only, "Schema only", :boolean),
        input(:local_port, "Local port", :integer),
        input(:clean, "Clean before restore", :boolean),
        input(:jobs, "Parallel jobs", :integer),
        input(:resource_group, "Resource group", :string),
        input(:pem, "PEM file", :string),
        input(:backend, "Backend", :string),
        input(:bucket, "S3 bucket", :string),
        input(:state_region, "State region", :string)
      ]
    },
    %{
      task: "terraform.show_password",
      module: Mix.Tasks.Terraform.ShowPassword,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean),
        input(:backend, "Backend", :string),
        input(:bucket, "S3 bucket", :string),
        input(:region, "AWS region", :string)
      ]
    },

    # ─── Load Test ─────────────────────────────────────────────────────
    %{
      task: "deploy_ex.load_test.create_instance",
      module: Mix.Tasks.DeployEx.LoadTest.CreateInstance,
      category: "Load Test",
      inputs: [
        input(:instance_type, "Instance type", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:resource_group, "Resource group", :string),
        input(:pem, "PEM file", :string)
      ]
    },
    %{
      task: "deploy_ex.load_test.destroy_instance",
      module: Mix.Tasks.DeployEx.LoadTest.DestroyInstance,
      category: "Load Test",
      inputs: [
        input(:instance_id, "Instance ID", :string),
        input(:all, "All runners", :boolean),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test",
      module: Mix.Tasks.DeployEx.LoadTest,
      category: "Load Test",
      inputs: [
        input(:command, "Command help", :string, description: "Show help for a specific load_test subcommand")
      ]
    },
    %{
      task: "deploy_ex.load_test.exec",
      module: Mix.Tasks.DeployEx.LoadTest.Exec,
      category: "Load Test",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:script, "Script filename", :string),
        input(:target_url, "Target URL", :string),
        input(:prometheus_url, "Prometheus URL", :string),
        input(:instance_id, "Instance ID", :string),
        input(:pem, "PEM file", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test.init",
      module: Mix.Tasks.DeployEx.LoadTest.Init,
      category: "Load Test",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        )
      ]
    },
    %{
      task: "deploy_ex.load_test.list",
      module: Mix.Tasks.DeployEx.LoadTest.List,
      category: "Load Test",
      inputs: [
        input(:json, "JSON output", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test.upload",
      module: Mix.Tasks.DeployEx.LoadTest.Upload,
      category: "Load Test",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:script, "Script path", :string, description: "Path to a specific script (default: all scripts for the app)"),
        input(:instance_id, "Instance ID", :string),
        input(:pem, "PEM file", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    }
  ]
  end

  @spec all_commands() :: list(command_def())
  def all_commands, do: build_commands()

  @spec categories() :: list(String.t())
  def categories do
    build_commands()
    |> Enum.map(& &1.category)
    |> Enum.uniq()
  end

  @spec commands_for_category(String.t()) :: list(command_def())
  def commands_for_category(category) do
    Enum.filter(build_commands(), &(&1.category === category))
  end

  @spec find_command(String.t()) :: command_def() | nil
  def find_command(task_name) do
    Enum.find(build_commands(), &(&1.task === task_name))
  end

  @spec shortdoc_for(command_def()) :: String.t()
  def shortdoc_for(%{module: module}) do
    Mix.Task.shortdoc(module) || ""
  end

  @spec moduledoc_for(command_def()) :: String.t()
  def moduledoc_for(%{module: module}) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} -> doc
      _ -> ""
    end
  end

  @spec args_to_cli_list(command_def(), keyword()) :: list(String.t())
  def args_to_cli_list(%{inputs: inputs}, values) do
    {positional, flags} = Enum.split_with(inputs, & &1.positional)

    positional_args =
      positional
      |> Enum.map(fn input -> Keyword.get(values, input.key) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    flag_args =
      Enum.flat_map(flags, fn input ->
        value = Keyword.get(values, input.key)

        cond do
          is_nil(value) -> []
          value === false -> []
          value === true -> ["--#{dasherize(input.key)}"]
          true -> ["--#{dasherize(input.key)}", to_string(value)]
        end
      end)

    positional_args ++ flag_args
  end

  @spec search(String.t()) :: list(command_def())
  def search(""), do: build_commands()

  def search(query) do
    query_lower = String.downcase(query)

    build_commands()
    |> Enum.map(fn cmd ->
      task_score = String.jaro_distance(query_lower, String.downcase(cmd.task))
      shortdoc = shortdoc_for(cmd)
      shortdoc_score = if shortdoc !== "", do: String.jaro_distance(query_lower, String.downcase(shortdoc)), else: 0.0
      category_score = String.jaro_distance(query_lower, String.downcase(cmd.category))

      contains_bonus = if String.contains?(String.downcase(cmd.task), query_lower) or
                          String.contains?(String.downcase(shortdoc), query_lower), do: 0.2, else: 0.0

      score = max(task_score, max(shortdoc_score, category_score)) + contains_bonus
      {cmd, score}
    end)
    |> Enum.filter(fn {_, score} -> score > 0.4 end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.map(fn {cmd, _} -> cmd end)
  end

  defp dasherize(atom), do: atom |> to_string() |> String.replace("_", "-")
end
