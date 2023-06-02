defmodule Mix.Tasks.DeployEx.RestartMachine do
  use Mix.Task

  @shortdoc "Stops and starts the machine for a specific app"
  @moduledoc """
  Stops and starts the machine for a specific app rebooting the machine and moving the code
  to different hardware

  ## Example
  ```bash
  $ mix deploy_ex.restart_machine my_app
  ```
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
