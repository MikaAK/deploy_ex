defmodule Mix.Tasks.DeployEx.FullSetup do
  use Mix.Task

  @shortdoc "Performs complete infrastructure and application setup using Terraform and Ansible"
  @moduledoc """
  Performs a complete setup of your infrastructure and application deployment using Terraform and Ansible.

  This task runs through the following steps:
  1. Builds and applies Terraform configuration to provision infrastructure
  2. Builds Ansible configuration for server management
  3. Waits for servers to fully initialize
  4. Pings servers to verify connectivity
  5. Runs Ansible setup to configure servers
  6. Deploys the application (unless skipped)

  ## Example
  ```bash
  # Run complete setup with all confirmations
  mix deploy_ex.full_setup

  # Skip confirmations and deploy automatically
  mix deploy_ex.full_setup --auto-approve

  # Setup infrastructure but skip final deployment
  mix deploy_ex.full_setup --skip-deploy
  ```

  ## Options
  - `auto-approve` - Skip Terraform plan confirmation prompts (alias: `y`)
  - `skip-deploy` - Skip application deployment after server setup (alias: `k`)
  - `skip-setup` - Skip waiting period between infrastructure creation and setup (alias: `p`)
  - `auto_pull_aws` - Automatically pull AWS credentials from host machine (alias: `a`)
  """

  alias Mix.Tasks.{Ansible, Terraform}

  @pre_setup_commands [
    Terraform.CreateStateBucket,
    Terraform.Build,
    Terraform.Apply,
    Ansible.Build
  ]

  @post_setup_comands [
    Mix.Tasks.DeployEx.Upload,
    Ansible.Deploy
  ]

  @time_between_pre_post :timer.seconds(10)

  def run(args) do
    with :ok <- DeployExHelpers.check_in_umbrella() do
      case run_commands(@pre_setup_commands, args) do
        nil ->
          opts = parse_args(args)

          if !opts[:skip_setup] do
            Mix.shell().info([
              :green, "* sleeping for ", :reset,
              @time_between_pre_post |> div(1000) |> to_string,
              :green, " seconds to allow setup"
            ])

            Process.sleep(@time_between_pre_post)
          end

          ping_and_run_post_setup(args)

        e -> Mix.raise(e)
      end
    end
  end

  defp parse_args(args) do
    {opts, _extra_args} = OptionParser.parse!(args,
      aliases: [k: :skip_deploy, p: :skip_setup],
      switches: [
        skip_setup: :boolean,
        skip_deploy: :boolean
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

  defp ping_and_run_post_setup(args) do
    opts = parse_args(args)

    with :ok <- Ansible.Ping.run(args),
         :ok <- run_setup(opts, args) do

      if !opts[:skip_deploy] do
        Mix.shell().info([
          :green, "* running post setup"
        ])

        run_commands(@post_setup_comands, args)
      end
    end
  end

  defp run_setup(opts, args) do
    if !opts[:skip_setup] do
      Mix.shell().info([
        :green, "* running instance setup"
      ])

      Ansible.Setup.run(args)
    end
  end
end
