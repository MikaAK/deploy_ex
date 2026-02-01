defmodule Mix.Tasks.DeployEx.Autoscale.Status do
  use Mix.Task

  alias DeployEx.AwsAutoscaling

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
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, remaining_args} = OptionParser.parse!(args,
      aliases: [e: :environment],
      switches: [environment: :string]
    )

    app_name = case remaining_args do
      [name | _] -> name
      [] -> Mix.raise("Application name is required. Usage: mix deploy_ex.autoscale.status <app_name>")
    end

    environment = Keyword.get(opts, :environment, Mix.env() |> to_string())

    with :ok <- DeployExHelpers.check_in_umbrella() do
      Mix.shell().info([:blue, "Fetching autoscaling status for #{app_name}..."])

      case AwsAutoscaling.find_asg_by_prefix(app_name, environment) do
        {:ok, []} ->
          asg_name = AwsAutoscaling.build_asg_name(app_name, environment)
          case AwsAutoscaling.describe_auto_scaling_group(asg_name) do
            {:ok, asg_data} ->
              display_status(asg_data, asg_name)

            {:error, %ErrorMessage{code: :not_found}} ->
              Mix.shell().info([:yellow, "\nAutoscaling is not enabled for #{app_name} or the group does not exist."])
              Mix.shell().info("To enable autoscaling, set enable_autoscaling = true in your Terraform variables.")

            {:error, error} ->
              Mix.shell().error([:red, "\nError fetching autoscaling status: #{inspect(error)}"])
          end

        {:ok, asgs} ->
          Enum.each(asgs, fn asg_data ->
            display_status(asg_data, asg_data.name)
          end)

        {:error, error} ->
          Mix.shell().error([:red, "\nError fetching autoscaling status: #{inspect(error)}"])
      end
    end
  end

  defp display_status(asg_data, asg_name) do
    instance_count = length(asg_data.instances)

    Mix.shell().info([
      :green, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
      :bright, "Autoscaling Group: ", :normal, asg_name, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    ])

    Mix.shell().info([
      :cyan, "Capacity:\n",
      :reset, "  Desired: ", :bright, "#{asg_data.desired_capacity}", :reset, "\n",
      "  Minimum: #{asg_data.min_size}\n",
      "  Maximum: #{asg_data.max_size}\n"
    ])

    Mix.shell().info([
      :cyan, "\nCurrent Instances: ", :bright, "#{instance_count}", :reset, "\n"
    ])

    if instance_count > 0 do
      Enum.each(asg_data.instances, fn instance ->
        state_color = case instance.lifecycle_state do
          "InService" -> :green
          "Pending" -> :yellow
          _ -> :red
        end

        Mix.shell().info([
          "  • ", state_color, instance.instance_id, :reset,
          " (", instance.lifecycle_state, ", ", instance.health_status, ") - ", instance.availability_zone
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
    case AwsAutoscaling.describe_scaling_policies(asg_name) do
      {:ok, [_ | _] = policies} ->
        Mix.shell().info([
          :cyan, "\nScaling Policies:\n"
        ])

        Enum.each(policies, fn policy ->
          Mix.shell().info(["  • ", :bright, policy.policy_name, :reset, " (#{policy.policy_type})"])

          if target_config = policy.target_tracking_configuration do
            if target_config.predefined_metric_type do
              Mix.shell().info([
                "    Target: ", :bright, "#{target_config.target_value}%", :reset,
                " #{target_config.predefined_metric_type}"
              ])
            end
          end
        end)

      _ ->
        nil
    end
  end
end
