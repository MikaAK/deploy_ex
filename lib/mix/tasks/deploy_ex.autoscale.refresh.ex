defmodule Mix.Tasks.DeployEx.Autoscale.Refresh do
  use Mix.Task

  alias DeployEx.AwsAutoscaling

  @shortdoc "Triggers an instance refresh to recreate autoscaling instances"
  @moduledoc """
  Triggers an instance refresh on an Auto Scaling Group to replace all instances
  with new ones. New instances will run cloud-init and pull the current release from S3.

  This uses the "launch before terminating" strategy, meaning new instances are
  launched and must pass health checks before old instances are terminated.

  ## Usage

      mix deploy_ex.autoscale.refresh <app_name>

  ## Examples

      mix deploy_ex.autoscale.refresh my_app
      mix deploy_ex.autoscale.refresh my_app --min-healthy-percentage 90
      mix deploy_ex.autoscale.refresh my_app --wait

  ## Options

  - `--environment` or `-e` - Environment name (default: Mix.env())
  - `--min-healthy-percentage` - Minimum healthy instances during refresh (default: 100)
  - `--instance-warmup` - Seconds to wait for instance warmup (default: 300)
  - `--wait` or `-w` - Wait for refresh to complete
  - `--skip-matching` - Skip instances that already match the launch template
  """

  @default_min_healthy_percentage 100
  @default_instance_warmup 300

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, remaining_args} = OptionParser.parse!(args,
      aliases: [e: :environment, w: :wait],
      switches: [
        environment: :string,
        min_healthy_percentage: :integer,
        instance_warmup: :integer,
        wait: :boolean,
        skip_matching: :boolean
      ]
    )

    app_name = case remaining_args do
      [name | _] -> name
      [] -> Mix.raise("Application name is required. Usage: mix deploy_ex.autoscale.refresh <app_name>")
    end

    environment = Keyword.get(opts, :environment, Mix.env() |> to_string())
    min_healthy = Keyword.get(opts, :min_healthy_percentage, @default_min_healthy_percentage)
    instance_warmup = Keyword.get(opts, :instance_warmup, @default_instance_warmup)
    skip_matching = Keyword.get(opts, :skip_matching)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      Mix.shell().info([:blue, "Starting instance refresh for #{app_name}..."])

      preferences = %{
        min_healthy_percentage: min_healthy,
        instance_warmup: instance_warmup,
        skip_matching: skip_matching
      }

      case AwsAutoscaling.find_asg_by_prefix(app_name, environment) do
        {:ok, []} ->
          asg_name = AwsAutoscaling.build_asg_name(app_name, environment)
          start_refresh_for_asg(asg_name, app_name, preferences, opts)

        {:ok, asgs} ->
          Enum.each(asgs, fn asg ->
            start_refresh_for_asg(asg.name, app_name, preferences, opts)
          end)

        {:error, error} ->
          Mix.shell().error([:red, "\nError finding autoscaling groups: #{inspect(error)}\n"])
      end
    end
  end

  defp start_refresh_for_asg(asg_name, app_name, preferences, opts) do
    Mix.shell().info([
      "\n  ASG: ", :bright, asg_name, :reset, "\n",
      "  Strategy: ", :bright, "Launch before terminating", :reset, "\n",
      "  Min healthy: ", :bright, "#{preferences.min_healthy_percentage}%", :reset, "\n",
      "  Instance warmup: ", :bright, "#{preferences.instance_warmup}s", :reset
    ])

    case AwsAutoscaling.start_instance_refresh(asg_name, preferences) do
      {:ok, refresh_id} ->
        Mix.shell().info([
          :green, "\n✓ Instance refresh started successfully.\n",
          :reset, "  Refresh ID: ", :bright, refresh_id, :reset
        ])

        if opts[:wait] do
          wait_for_refresh(asg_name, refresh_id)
        else
          Mix.shell().info([
            "\nRun ", :bright, "mix deploy_ex.autoscale.refresh_status #{app_name}", :reset,
            " to check progress."
          ])
        end

      {:error, %ErrorMessage{code: :not_found}} ->
        Mix.shell().error([
          :red, "\nError: Autoscaling group '#{asg_name}' not found.\n"
        ])
        Mix.shell().info("Ensure autoscaling is enabled for #{app_name} in your Terraform configuration.")

      {:error, %ErrorMessage{code: :conflict}} ->
        Mix.shell().error([
          :red, "\nError: An instance refresh is already in progress.\n"
        ])
        Mix.shell().info("Wait for the current refresh to complete or cancel it first.")

      {:error, error} ->
        Mix.shell().error([
          :red, "\nError starting instance refresh: #{inspect(error)}\n"
        ])
    end
  end

  defp wait_for_refresh(asg_name, refresh_id) do
    Mix.shell().info([:yellow, "\nWaiting for instance refresh to complete..."])

    Stream.interval(10_000)
    |> Enum.reduce_while(:pending, fn _, _ ->
      case AwsAutoscaling.describe_instance_refreshes(asg_name, refresh_ids: [refresh_id]) do
        {:ok, [%{status: "Successful"} | _]} ->
          Mix.shell().info([:green, "\n✓ Instance refresh completed successfully!"])
          {:halt, :ok}

        {:ok, [%{status: "Failed", status_reason: reason} | _]} ->
          Mix.shell().error([:red, "\n✗ Instance refresh failed: #{reason}"])
          {:halt, {:error, reason}}

        {:ok, [%{status: "Cancelled"} | _]} ->
          Mix.shell().info([:yellow, "\n⚠ Instance refresh was cancelled."])
          {:halt, :cancelled}

        {:ok, [%{status: status, percentage_complete: percent} | _]} ->
          Mix.shell().info([:blue, "  Progress: #{percent || 0}% (#{status})"])
          {:cont, :pending}

        {:ok, []} ->
          Mix.shell().error([:red, "\nRefresh not found"])
          {:halt, {:error, "Refresh not found"}}

        {:error, error} ->
          Mix.shell().error([:red, "\nError checking refresh status: #{inspect(error)}"])
          {:halt, {:error, error}}
      end
    end)
  end
end
