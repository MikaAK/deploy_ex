defmodule Mix.Tasks.DeployEx.FullSetup do
  use Mix.Task

  @shortdoc "Bootstraps AWS infrastructure and configures servers via Terraform and Ansible"
  @moduledoc """
  Provisions AWS infrastructure with Terraform and bootstraps servers with Ansible.

  This task runs through the following steps:
  1. Builds and applies Terraform configuration to provision infrastructure
  2. Builds Ansible configuration for server management
  3. Waits for servers to fully initialize
  4. Pings servers to verify connectivity
  5. Runs Ansible setup to configure servers

  Releases are deployed by your CI pipeline (see
  `mix deploy_ex.install_github_action`). Once `full_setup` completes, push to
  your main branch — or run `mix deploy_ex.release && mix deploy_ex.upload &&
  mix ansible.deploy` locally — to deploy.

  ## Example
  ```bash
  # Default — interactive
  mix deploy_ex.full_setup

  # Auto-approve every prompt
  mix deploy_ex.full_setup --auto-approve

  # Skip the wait + ansible.setup steps (infra-only)
  mix deploy_ex.full_setup --skip-setup
  ```

  ## Options
  - `auto-approve` - Skip Terraform plan confirmation prompts (alias: `y`)
  - `skip-setup` - Skip waiting period and `ansible.setup` (alias: `p`)
  - `auto_pull_aws` - Pull AWS credentials from `~/.aws/credentials` (alias: `a`)
  """

  alias Mix.Tasks.{Ansible, Terraform}

  @pre_setup_commands [
    Terraform.CreateStateBucket,
    Terraform.CreateStateLockTable,
    Terraform.Build,
    Terraform.Apply,
    Terraform.Refresh,
    Ansible.Build
  ]

  @time_between_pre_post :timer.seconds(10)

  def run(args) do
    with :ok <- DeployExHelpers.check_valid_project() do
      result = run_commands(@pre_setup_commands, args)

      if is_nil(result) do
        opts = parse_args(args)

        DeployEx.TUI.setup_no_tui(opts)

        unless opts[:skip_setup] do
          wait_seconds = div(@time_between_pre_post, 1000)
          run_setup_countdown(wait_seconds)
        end

        ping_and_run_setup(args)
      else
        Mix.raise(result)
      end
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [p: :skip_setup],
      switches: [
        skip_setup: :boolean,
        no_tui: :boolean
      ]
    )

    opts
  end

  defp run_commands(commands, args) do
    Enum.find_value(commands, fn cmd_mod ->
      case cmd_mod.run(args) do
        :ok -> false
        {:error, _} = e -> e
      end
    end)
  end

  defp ping_and_run_setup(args) do
    opts = parse_args(args)

    with :ok <- Ansible.Ping.run(args),
         :ok <- run_setup(opts, args) do
      Mix.shell().info([
        :green, "\n* infrastructure ready. Push to your main branch — or run ",
        :bright, "mix deploy_ex.release && mix deploy_ex.upload && mix ansible.deploy",
        :reset, :green, " — to deploy."
      ])
    end
  end

  defp run_setup(opts, args) do
    if opts[:skip_setup] do
      :ok
    else
      Mix.shell().info([
        :green, "* running instance setup"
      ])

      Ansible.Setup.run(args)
    end
  end

  defp run_setup_countdown(total_seconds) do
    steps = Enum.map(1..total_seconds, fn second ->
      {"Waiting for servers to initialize (#{second}/#{total_seconds}s)...", fn ->
        Process.sleep(1000)
        :ok
      end}
    end)

    DeployEx.TUI.Progress.run_steps(steps, title: "Server Initialization")
  end
end
