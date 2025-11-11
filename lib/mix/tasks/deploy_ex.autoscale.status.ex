defmodule Mix.Tasks.DeployEx.Autoscale.Status do
  use Mix.Task

  @shortdoc "Displays autoscaling group status for an application"
  @moduledoc """
  Displays the current status of an Auto Scaling Group including:
  - Desired, minimum, and maximum capacity
  - Current instance count and IDs
  - Instance lifecycle states
  - Scaling policy configuration

  ## Usage

      mix deploy_ex.autoscale.status <app_name>

  ## Examples

      mix deploy_ex.autoscale.status my_app
      mix deploy_ex.autoscale.status my_app_redis

  ## Options

  - `--environment` or `-e` - Environment name (default: Mix.env())
  """

  def run(args) do
    {opts, remaining_args} = OptionParser.parse!(args,
      aliases: [e: :environment],
      switches: [environment: :string]
    )

    app_name = case remaining_args do
      [name | _] -> name
      [] -> Mix.raise("Application name is required. Usage: mix deploy_ex.autoscale.status <app_name>")
    end

    environment = Keyword.get(opts, :environment, Mix.env() |> to_string())

    with :ok <- check_aws_cli_installed(),
         :ok <- DeployExHelpers.check_in_umbrella() do
      asg_name = build_asg_name(app_name, environment)

      Mix.shell().info([:blue, "Fetching autoscaling status for #{app_name}..."])

      case describe_autoscaling_group(asg_name) do
        {:ok, asg_data} ->
          display_status(asg_data, asg_name)

        {:error, :not_found} ->
          Mix.shell().info([:yellow, "\nAutoscaling is not enabled for #{app_name} or the group does not exist."])
          Mix.shell().info("To enable autoscaling, set enable_autoscaling = true in your Terraform variables.")

        {:error, reason} ->
          Mix.shell().error([:red, "\nError fetching autoscaling status: #{reason}"])
      end
    end
  end

  defp check_aws_cli_installed do
    case System.cmd("which", ["aws"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ ->
        Mix.raise("""
        AWS CLI is not installed or not in PATH.
        Please install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
        """)
    end
  end

  defp build_asg_name(app_name, environment) do
    app_name
    |> String.replace("_", "-")
    |> Kernel.<>("-asg-#{environment}")
  end

  defp describe_autoscaling_group(asg_name) do
    case System.cmd("aws", [
      "autoscaling", "describe-auto-scaling-groups",
      "--auto-scaling-group-names", asg_name,
      "--output", "json"
    ], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"AutoScalingGroups" => [asg | _]}} ->
            {:ok, asg}

          {:ok, %{"AutoScalingGroups" => []}} ->
            {:error, :not_found}

          {:error, _} ->
            {:error, "Failed to parse AWS response"}
        end

      {error, _} ->
        if String.contains?(error, "does not exist") do
          {:error, :not_found}
        else
          {:error, error}
        end
    end
  end

  defp display_status(asg_data, asg_name) do
    desired = asg_data["DesiredCapacity"]
    min_size = asg_data["MinSize"]
    max_size = asg_data["MaxSize"]
    instances = asg_data["Instances"] || []
    instance_count = length(instances)

    Mix.shell().info([
      :green, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
      :bright, "Autoscaling Group: ", :normal, asg_name, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    ])

    Mix.shell().info([
      :cyan, "Capacity:\n",
      :reset, "  Desired: ", :bright, "#{desired}", :reset, "\n",
      "  Minimum: #{min_size}\n",
      "  Maximum: #{max_size}\n"
    ])

    Mix.shell().info([
      :cyan, "\nCurrent Instances: ", :bright, "#{instance_count}", :reset, "\n"
    ])

    if instance_count > 0 do
      Enum.each(instances, fn instance ->
        instance_id = instance["InstanceId"]
        lifecycle_state = instance["LifecycleState"]
        health_status = instance["HealthStatus"]
        az = instance["AvailabilityZone"]

        state_color = case lifecycle_state do
          "InService" -> :green
          "Pending" -> :yellow
          _ -> :red
        end

        Mix.shell().info([
          "  • ", state_color, instance_id, :reset,
          " (", lifecycle_state, ", ", health_status, ") - ", az
        ])
      end)
    else
      Mix.shell().info([:yellow, "  No instances currently running"])
    end

    display_scaling_policies(asg_name)

    Mix.shell().info([
      :green, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    ])
  end

  defp display_scaling_policies(asg_name) do
    case System.cmd("aws", [
      "autoscaling", "describe-policies",
      "--auto-scaling-group-name", asg_name,
      "--output", "json"
    ], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"ScalingPolicies" => policies}} when length(policies) > 0 ->
            Mix.shell().info([
              :cyan, "\nScaling Policies:\n"
            ])

            Enum.each(policies, fn policy ->
              policy_type = policy["PolicyType"]
              policy_name = policy["PolicyName"]

              Mix.shell().info(["  • ", :bright, policy_name, :reset, " (#{policy_type})"])

              if target_config = policy["TargetTrackingConfiguration"] do
                if predefined = target_config["PredefinedMetricSpecification"] do
                  metric_type = predefined["PredefinedMetricType"]
                  target_value = target_config["TargetValue"]

                  Mix.shell().info([
                    "    Target: ", :bright, "#{target_value}%", :reset,
                    " #{metric_type}"
                  ])
                end
              end
            end)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end
end
