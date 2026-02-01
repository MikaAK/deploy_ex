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

  ## Notes

  The desired capacity must be between the configured minimum and maximum
  values for the autoscaling group. AWS will reject values outside this range.
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, remaining_args} = OptionParser.parse!(args,
      aliases: [e: :environment],
      switches: [environment: :string]
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
      asg_name = AwsAutoscaling.build_asg_name(app_name, environment)

      Mix.shell().info([:blue, "Scaling #{app_name} to #{desired_capacity} instances..."])

      case AwsAutoscaling.set_desired_capacity(asg_name, desired_capacity) do
        :ok ->
          Mix.shell().info([
            :green, "\n✓ Successfully requested scaling to #{desired_capacity} instances.\n"
          ])
          Mix.shell().info([
            "Run ", :bright, "mix deploy_ex.autoscale.status #{app_name}", :reset,
            " to check the current status."
          ])

        {:error, %ErrorMessage{code: :not_found}} ->
          Mix.shell().error([
            :red, "\nError: Autoscaling group '#{asg_name}' not found.\n"
          ])
          Mix.shell().info("Ensure autoscaling is enabled for #{app_name} in your Terraform configuration.")

        {:error, %ErrorMessage{code: :bad_request} = error} ->
          if String.contains?(to_string(error), "outside") or String.contains?(to_string(error), "range") do
            Mix.shell().error([
              :red, "\nError: Desired capacity #{desired_capacity} is outside the min/max range.\n"
            ])
            Mix.shell().info("Check the autoscaling group's min_size and max_size configuration.")
          else
            Mix.shell().error([
              :red, "\nError setting desired capacity: #{inspect(error)}\n"
            ])
          end

        {:error, error} ->
          Mix.shell().error([
            :red, "\nError setting desired capacity: #{inspect(error)}\n"
          ])
      end
    end
  end
end
