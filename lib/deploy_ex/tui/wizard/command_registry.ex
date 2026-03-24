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
        input(:auto_approve, "Auto-approve Terraform", :boolean, description: "Skip Terraform plan confirmation"),
        input(:skip_deploy, "Skip deploy", :boolean, description: "Skip application deployment after server setup"),
        input(:skip_setup, "Skip setup wait", :boolean, description: "Skip waiting period between infra creation and setup")
      ]
    },
    %{
      task: "deploy_ex.full_drop",
      module: Mix.Tasks.DeployEx.FullDrop,
      category: "DeployEx",
      inputs: [
        input(:force, "Force", :boolean, description: "Skip confirmation prompts")
      ]
    },
    %{
      task: "deploy_ex.install_github_action",
      module: Mix.Tasks.DeployEx.InstallGithubAction,
      category: "DeployEx",
      inputs: [
        input(:force, "Force overwrite", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.install_migration_script",
      module: Mix.Tasks.DeployEx.InstallMigrationScript,
      category: "DeployEx",
      inputs: [
        input(:force, "Force overwrite", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.release",
      module: Mix.Tasks.DeployEx.Release,
      category: "DeployEx",
      inputs: [
        input(:force, "Force rebuild", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.upload",
      module: Mix.Tasks.DeployEx.Upload,
      category: "DeployEx",
      inputs: [
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean),
        input(:aws_region, "AWS region", :string, description: "Override AWS region")
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
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
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
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
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
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
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
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
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
        input(:index, "Instance index", :integer, description: "Connect to a specific instance (0-based)"),
        input(:log, "View logs", :boolean),
        input(:iex, "IEx remote", :boolean),
        input(:root, "Root access", :boolean),
        input(:list, "List instances", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.ssh.authorize",
      module: Mix.Tasks.DeployEx.Ssh.Authorize,
      category: "DeployEx",
      inputs: [
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
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
        input(:file, "Remote file path", :string, required: true),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.find_nodes",
      module: Mix.Tasks.DeployEx.FindNodes,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.select_node",
      module: Mix.Tasks.DeployEx.SelectNode,
      category: "DeployEx",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        )
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
        )
      ]
    },
    %{
      task: "deploy_ex.list_available_releases",
      module: Mix.Tasks.DeployEx.ListAvailableReleases,
      category: "DeployEx",
      inputs: [
        input(:quiet, "Quiet", :boolean)
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
        )
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
        input(:aws_region, "AWS region", :string),
        input(:quiet, "Quiet", :boolean)
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
        input(:aws_region, "AWS region", :string),
        input(:quiet, "Quiet", :boolean)
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
        input(:watch, "Watch (auto-refresh)", :boolean),
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
        input(:wait, "Wait for completion", :boolean),
        input(:environment, "Environment", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.autoscale.refresh_status",
      module: Mix.Tasks.DeployEx.Autoscale.RefreshStatus,
      category: "Autoscaling",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:environment, "Environment", :string)
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
        input(:sha, "Git SHA", :string, required: true, description: "Target git SHA to deploy"),
        input(:instance_type, "Instance type", :string, default: "t3.small"),
        input(:skip_setup, "Skip setup", :boolean),
        input(:skip_deploy, "Skip deploy", :boolean),
        input(:attach_lb, "Attach to load balancer", :boolean),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.qa.destroy",
      module: Mix.Tasks.DeployEx.Qa.Destroy,
      category: "QA",
      inputs: [
        input(:app_name, "App name", :select,
          required: true,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.qa.list",
      module: Mix.Tasks.DeployEx.Qa.List,
      category: "QA",
      inputs: [
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
        input(:sha, "Git SHA", :string, required: true),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
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
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.qa.cleanup",
      module: Mix.Tasks.DeployEx.Qa.Cleanup,
      category: "QA",
      inputs: [
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
        input(:directory, "Ansible directory", :string),
        input(:force, "Force overwrite", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "ansible.deploy",
      module: Mix.Tasks.Ansible.Deploy,
      category: "Ansible",
      inputs: [
        input(:only, "Only app(s)", :string, description: "Comma-separated app names to deploy"),
        input(:except, "Except app(s)", :string, description: "Comma-separated app names to skip"),
        input(:target_sha, "Target SHA", :string, description: "Deploy specific release SHA"),
        input(:parallel, "Max concurrency", :integer, default: 4),
        input(:only_local_release, "Only local releases", :boolean),
        input(:include_qa, "Include QA nodes", :boolean),
        input(:qa, "QA nodes only", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "ansible.ping",
      module: Mix.Tasks.Ansible.Ping,
      category: "Ansible",
      inputs: [
        input(:directory, "Ansible directory", :string),
        input(:quiet, "Quiet", :boolean)
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
        input(:sha, "Target SHA", :string, description: "Rollback to this SHA"),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "ansible.setup",
      module: Mix.Tasks.Ansible.Setup,
      category: "Ansible",
      inputs: [
        input(:only, "Only app(s)", :string),
        input(:except, "Except app(s)", :string),
        input(:directory, "Ansible directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },

    # ─── Terraform ─────────────────────────────────────────────────────
    %{
      task: "terraform.apply",
      module: Mix.Tasks.Terraform.Apply,
      category: "Terraform",
      inputs: [
        input(:auto_approve, "Auto-approve", :boolean),
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.build",
      module: Mix.Tasks.Terraform.Build,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:aws_region, "AWS region", :string),
        input(:aws_bucket, "AWS release bucket", :string),
        input(:aws_log_bucket, "AWS log bucket", :string),
        input(:env, "Environment", :string),
        input(:force, "Force overwrite", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.create_state_bucket",
      module: Mix.Tasks.Terraform.CreateStateBucket,
      category: "Terraform",
      inputs: [
        input(:aws_region, "AWS region", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.create_state_lock_table",
      module: Mix.Tasks.Terraform.CreateStateLockTable,
      category: "Terraform",
      inputs: [
        input(:aws_region, "AWS region", :string),
        input(:quiet, "Quiet", :boolean)
      ]
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
        input(:aws_region, "AWS region", :string),
        input(:quiet, "Quiet", :boolean)
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
        input(:aws_region, "AWS region", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.drop",
      module: Mix.Tasks.Terraform.Drop,
      category: "Terraform",
      inputs: [
        input(:auto_approve, "Auto-approve", :boolean),
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.drop_state_bucket",
      module: Mix.Tasks.Terraform.DropStateBucket,
      category: "Terraform",
      inputs: [
        input(:aws_region, "AWS region", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.drop_state_lock_table",
      module: Mix.Tasks.Terraform.DropStateLockTable,
      category: "Terraform",
      inputs: [
        input(:aws_region, "AWS region", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.dump_database",
      module: Mix.Tasks.Terraform.DumpDatabase,
      category: "Terraform",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.generate_pem",
      module: Mix.Tasks.Terraform.GeneratePem,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.init",
      module: Mix.Tasks.Terraform.Init,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.output",
      module: Mix.Tasks.Terraform.Output,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.plan",
      module: Mix.Tasks.Terraform.Plan,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.refresh",
      module: Mix.Tasks.Terraform.Refresh,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
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
        input(:directory, "Terraform directory", :string),
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.restore_database",
      module: Mix.Tasks.Terraform.RestoreDatabase,
      category: "Terraform",
      inputs: [
        input(:app_name, "App name", :select,
          positional: true,
          choices_fn: &__MODULE__.fetch_app_names/0
        ),
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "terraform.show_password",
      module: Mix.Tasks.Terraform.ShowPassword,
      category: "Terraform",
      inputs: [
        input(:directory, "Terraform directory", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },

    # ─── Load Test ─────────────────────────────────────────────────────
    %{
      task: "deploy_ex.load_test.create_instance",
      module: Mix.Tasks.DeployEx.LoadTest.CreateInstance,
      category: "Load Test",
      inputs: [
        input(:instance_type, "Instance type", :string),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test.destroy_instance",
      module: Mix.Tasks.DeployEx.LoadTest.DestroyInstance,
      category: "Load Test",
      inputs: [
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test",
      module: Mix.Tasks.DeployEx.LoadTest,
      category: "Load Test",
      inputs: [
        input(:duration, "Duration (seconds)", :integer),
        input(:rate, "Request rate", :integer),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test.exec",
      module: Mix.Tasks.DeployEx.LoadTest.Exec,
      category: "Load Test",
      inputs: [
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test.init",
      module: Mix.Tasks.DeployEx.LoadTest.Init,
      category: "Load Test",
      inputs: [
        input(:force, "Force", :boolean),
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test.list",
      module: Mix.Tasks.DeployEx.LoadTest.List,
      category: "Load Test",
      inputs: [
        input(:quiet, "Quiet", :boolean)
      ]
    },
    %{
      task: "deploy_ex.load_test.upload",
      module: Mix.Tasks.DeployEx.LoadTest.Upload,
      category: "Load Test",
      inputs: [
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
