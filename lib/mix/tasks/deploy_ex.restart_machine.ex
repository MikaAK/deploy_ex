defmodule Mix.Tasks.DeployEx.RestartMachine do
  use Mix.Task

  @shortdoc "Restarts EC2 instances for a specific application"
  @moduledoc """
  Stops and restarts EC2 instances running a specific application. This performs a full
  stop/start cycle rather than just a reboot, which can move instances to different
  underlying hardware.

  This task:
  1. Finds all EC2 instances tagged with the given application name
  2. Prompts for selection of specific instances to restart
  3. Gracefully stops the selected instances and waits for complete shutdown
  4. Starts the instances (potentially on different hardware)
  5. Waits for instances to reach running state and pass health checks

  This is useful for:
  - Moving instances to different underlying hardware if experiencing host issues
  - Resolving persistent instance-level problems that survive reboots
  - Testing instance recovery procedures and failover
  - Applying certain types of EC2 host maintenance

  ## Example
  ```bash
  # Restart all instances for my_app
  mix deploy_ex.restart_machine my_app

  # Restart instances with additional AWS options
  mix deploy_ex.restart_machine my_app --aws-region us-east-1
  ```

  ## Options
  - `--aws-region` - AWS region to operate in (default: configured region)
  - `--resource-group` - Specify a custom resource group name
  - `--force` - Skip confirmation prompts (alias: `f`)
  - `--quiet` - Suppress non-essential output (alias: `q`)

  The task will prompt for confirmation before stopping instances unless --force is used.
  It will wait for instances to fully stop before starting them again and verify they
  reach a running state.
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, node_name_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet],
      switches: [
        aws_region: :string,
        resource_group: :string,
        force: :boolean,
        quiet: :boolean,
        no_tui: :boolean
      ]
    )

    DeployEx.TUI.setup_no_tui(opts)

    with {:ok, app_name} <- DeployExHelpers.find_project_name(node_name_args),
         {:ok, instances} <- DeployEx.AwsMachine.fetch_instance_ids_by_tags([{"InstanceGroup", app_name}], region: opts[:aws_region], resource_group: opts[:resource_group]) do
      instance_names = choose_instances(instances)
      instance_ids = Enum.map(instance_names, &instances[&1])
      names_label = Enum.join(instance_names, ", ")

      steps = [
        {"Stopping instances: #{names_label}", fn ->
          DeployEx.AwsMachine.stop(instance_ids)
        end},
        {"Waiting for instances to stop...", fn ->
          DeployEx.AwsMachine.wait_for_stopped(instance_ids)
        end},
        {"Starting instances: #{names_label}", fn ->
          DeployEx.AwsMachine.start(instance_ids)
        end},
        {"Waiting for instances to start...", fn ->
          DeployEx.AwsMachine.wait_for_started(instance_ids)
        end}
      ]

      case DeployEx.TUI.Progress.run_steps(steps, title: "Restarting #{names_label}") do
        :ok -> :ok
        {:error, error} -> Mix.raise(to_string(error))
      end
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp choose_instances(instances) do
    DeployExHelpers.prompt_for_choice(Map.keys(instances), true)
  end
end
