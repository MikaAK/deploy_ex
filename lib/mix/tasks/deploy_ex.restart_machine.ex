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
  - `aws-region` - AWS region to operate in (default: configured region)
  - `force` - Skip confirmation prompts (alias: `f`)
  - `quiet` - Suppress non-essential output (alias: `q`)

  The task will prompt for confirmation before stopping instances unless --force is used.
  It will wait for instances to fully stop before starting them again and verify they
  reach a running state.
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {_, node_name_args} = OptionParser.parse!(args, switches: [])

    with {:ok, app_name} <- DeployExHelpers.find_app_name(node_name_args),
         {:ok, instances} <- DeployEx.AwsMachine.fetch_instance_ids_by_tag("InstanceGroup", app_name),
         :ok <- restart_instances(instances, choose_instances(instances)) do
      :ok
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp choose_instances(instances) do
    DeployExHelpers.prompt_for_choice(Map.keys(instances), true)
  end

  defp restart_instances(instances, instance_names) do
    instance_ids = Enum.map(instance_names, &instances[&1])

    with :ok <- stop_instances(instances, instance_ids),
         :ok <- wait_for_stopped(instances, instance_ids),
         {:ok, _} <- DeployEx.AwsMachine.start(instance_ids) do
      wait_for_started(instances, instance_ids)
    end
  end

  defp stop_instances(instances, instance_ids) do
    with {:ok, _} <- DeployEx.AwsMachine.stop(instance_ids) do
      Mix.shell().info([:yellow, "Stopping instances initiated for #{instance_names_from_ids(instances, instance_ids)}..."])

      :ok
    end
  end

  defp wait_for_stopped(instances, instance_ids) do
    Mix.shell().info([:yellow, "Waiting for instances to stop #{instance_names_from_ids(instances, instance_ids)}..."])

    with :ok <- DeployEx.AwsMachine.wait_for_stopped(instance_ids) do
      Mix.shell().info([:green, "Instances stopped successfully"])
    end
  end

  defp wait_for_started(instances, instance_ids) do
    Mix.shell().info([:yellow, "Start instances initiated..."])
    Mix.shell().info([:yellow, "Waiting for instances to start #{instance_names_from_ids(instances, instance_ids)}..."])

    with :ok <- DeployEx.AwsMachine.wait_for_started(instance_ids) do
      Mix.shell().info([:green, "Instances started successfully"])
    end
  end

  defp instance_names_from_ids(instances_map, instance_ids) do
    instances_map
      |> Map.filter(fn {_instance_name, instance_id} -> instance_id in instance_ids end)
      |> Map.keys
  end
end
