defmodule Mix.Tasks.DeployEx.Autoscale.Scale do
  use Mix.Task

  alias DeployEx.AwsAutoscaling

  @shortdoc "Manually set desired capacity of an autoscaling group"
  @moduledoc """
  Manually adjusts the desired capacity of an Auto Scaling Group.

  This command allows you to immediately scale an application up or down
  by setting the desired number of instances. AWS will launch or terminate
  instances to match the desired capacity.

  ## Usage

      mix deploy_ex.autoscale.scale <app_name> <desired_capacity>

  ## Examples

      mix deploy_ex.autoscale.scale my_app 5
      mix deploy_ex.autoscale.scale my_app_redis 3 --environment prod

  ## Options

  - `--environment` or `-e` - Environment name (default: Mix.env())
  - `--update-limits` or `-u` - Automatically update min/max capacity to accommodate the desired value
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, remaining_args} = OptionParser.parse!(args,
      aliases: [e: :environment, u: :update_limits],
      switches: [environment: :string, update_limits: :boolean]
    )

    {app_name, desired_capacity} = case remaining_args do
      [name, capacity] ->
        case Integer.parse(capacity) do
          {num, ""} when num >= 0 ->
            {name, num}

          _ ->
            Mix.raise("Desired capacity must be a non-negative integer. Got: #{capacity}")
        end

      _ ->
        Mix.raise("""
        Invalid arguments.
        Usage: mix deploy_ex.autoscale.scale <app_name> <desired_capacity>
        Example: mix deploy_ex.autoscale.scale my_app 3
        """)
    end

    environment = Keyword.get(opts, :environment, Mix.env() |> to_string())

    with :ok <- DeployExHelpers.check_in_umbrella() do
      Mix.shell().info([:blue, "Scaling #{app_name} to #{desired_capacity} instances..."])

      case AwsAutoscaling.find_asg_by_prefix(app_name, environment) do
        {:ok, []} ->
          asg_name = AwsAutoscaling.build_asg_name(app_name, environment)
          scale_asg(asg_name, app_name, desired_capacity, opts)

        {:ok, asgs} ->
          Enum.each(asgs, fn asg ->
            scale_asg(asg.name, app_name, desired_capacity, opts)
          end)

        {:error, error} ->
          Mix.raise("Error finding autoscaling groups: #{inspect(error)}")
      end
    end
  end

  defp scale_asg(asg_name, app_name, desired_capacity, opts) do
    Mix.shell().info(["\n  ASG: ", :bright, asg_name, :reset])

    if opts[:update_limits] do
      update_params = [min_size: desired_capacity, max_size: desired_capacity, desired_capacity: desired_capacity]

      Mix.shell().info([
        :faint, "  Updating limits: min=", to_string(update_params[:min_size]),
        ", max=", to_string(update_params[:max_size]),
        ", desired=", to_string(desired_capacity), :reset
      ])

      case AwsAutoscaling.update_auto_scaling_group(asg_name, update_params) do
        :ok ->
          Mix.shell().info([:green, "  ✓ Successfully scaled to #{desired_capacity} instances.\n"])
          Mix.shell().info([
            "  Run ", :bright, "mix deploy_ex.autoscale.status #{app_name}", :reset,
            " to check the current status."
          ])

        {:error, error} ->
          Mix.raise("Error updating autoscaling group: #{inspect(error)}")
      end
    else
      scale_with_set_desired(asg_name, app_name, desired_capacity)
    end
  end

  defp scale_with_set_desired(asg_name, app_name, desired_capacity) do
    case AwsAutoscaling.set_desired_capacity(asg_name, desired_capacity) do
      :ok ->
        Mix.shell().info([
          :green, "  ✓ Successfully requested scaling to #{desired_capacity} instances.\n"
        ])
        Mix.shell().info([
          "  Run ", :bright, "mix deploy_ex.autoscale.status #{app_name}", :reset,
          " to check the current status."
        ])

      {:error, %ErrorMessage{code: :not_found}} ->
        Mix.raise("Autoscaling group '#{asg_name}' not found")

      {:error, %ErrorMessage{code: :bad_request} = error} ->
        if String.contains?(to_string(error), "outside") or String.contains?(to_string(error), "range") do
          Mix.raise("Desired capacity #{desired_capacity} is outside the min/max range for #{asg_name}")
        else
          Mix.raise("Error setting desired capacity: #{inspect(error)}")
        end

      {:error, error} ->
        Mix.raise("Error setting desired capacity: #{inspect(error)}")
    end
  end
end
