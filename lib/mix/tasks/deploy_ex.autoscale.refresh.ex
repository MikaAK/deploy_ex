defmodule Mix.Tasks.DeployEx.Autoscale.Refresh do
  use Mix.Task

  alias DeployEx.AwsAutoscaling

  @shortdoc "Triggers an instance refresh to recreate autoscaling instances"
  @moduledoc """
  Triggers an instance refresh on an Auto Scaling Group to replace all instances
  with new ones. New instances will run cloud-init and pull the current release from S3.

  ## Usage

      mix deploy_ex.autoscale.refresh <app_name>

  ## Examples

      mix deploy_ex.autoscale.refresh my_app
      mix deploy_ex.autoscale.refresh my_app --availability launch-first
      mix deploy_ex.autoscale.refresh my_app --availability terminate-first
      mix deploy_ex.autoscale.refresh my_app --min-healthy-percentage 90 --max-healthy-percentage 100
      mix deploy_ex.autoscale.refresh my_app --wait

  ## Options

  - `--environment` or `-e` - Environment name (default: Mix.env())
  - `--strategy` or `-s` - Refresh strategy: Rolling (default) or ReplaceRootVolume
  - `--availability` or `-a` - Instance replacement availability behavior:
    - `launch-first` - Launch new instances before terminating old ones (min: 100%, max: 110%)
    - `terminate-first` - Terminate old instances before launching new ones (min: 90%, max: 100%)
  - `--min-healthy-percentage` - Minimum healthy instances during refresh (overrides --availability)
  - `--max-healthy-percentage` - Maximum healthy instances during refresh (overrides --availability)
  - `--instance-warmup` - Seconds to wait for instance warmup (default: 300)
  - `--wait` or `-w` - Wait for refresh to complete
  - `--skip-matching` - Skip instances that already match the launch template
  """

  @default_instance_warmup 300

  @availability_presets %{
    "launch-first" => %{min_healthy_percentage: 100, max_healthy_percentage: 110},
    "terminate-first" => %{min_healthy_percentage: 90, max_healthy_percentage: 100}
  }

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, remaining_args} = OptionParser.parse!(args,
      aliases: [e: :environment, w: :wait, s: :strategy, a: :availability],
      switches: [
        environment: :string,
        strategy: :string,
        availability: :string,
        min_healthy_percentage: :integer,
        max_healthy_percentage: :integer,
        instance_warmup: :integer,
        wait: :boolean,
        skip_matching: :boolean,
        no_tui: :boolean
      ]
    )

    DeployEx.TUI.setup_no_tui(opts)

    app_name = case remaining_args do
      [name | _] -> name
      [] -> Mix.raise("Application name is required. Usage: mix deploy_ex.autoscale.refresh <app_name>")
    end

    environment = Keyword.get(opts, :environment, Mix.env() |> to_string())
    strategy = Keyword.get(opts, :strategy, "Rolling")
    availability = Keyword.get(opts, :availability)
    instance_warmup = Keyword.get(opts, :instance_warmup, @default_instance_warmup)
    skip_matching = Keyword.get(opts, :skip_matching)

    availability_defaults = resolve_availability(availability)
    min_healthy = Keyword.get(opts, :min_healthy_percentage, availability_defaults.min_healthy_percentage)
    max_healthy = Keyword.get(opts, :max_healthy_percentage, availability_defaults.max_healthy_percentage)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      Mix.shell().info([:blue, "Starting instance refresh for #{app_name}..."])

      preferences = %{
        min_healthy_percentage: min_healthy,
        max_healthy_percentage: max_healthy,
        instance_warmup: instance_warmup,
        skip_matching: skip_matching
      }

      case AwsAutoscaling.find_asg_by_prefix(app_name, environment) do
        {:ok, []} ->
          asg_name = AwsAutoscaling.build_asg_name(app_name, environment)
          start_refresh_for_asg(asg_name, app_name, preferences, strategy, opts)

        {:ok, asgs} ->
          Enum.each(asgs, fn asg ->
            start_refresh_for_asg(asg.name, app_name, preferences, strategy, opts)
          end)

        {:error, error} ->
          Mix.shell().error([:red, "\nError finding autoscaling groups: #{inspect(error)}\n"])
      end
    end
  end

  defp start_refresh_for_asg(asg_name, app_name, preferences, strategy, opts) do
    Mix.shell().info([
      "\n  ASG: ", :bright, asg_name, :reset, "\n",
      "  Strategy: ", :bright, strategy, :reset, "\n",
      "  Availability: ", :bright, availability_label(preferences), :reset, "\n",
      "  Min healthy: ", :bright, "#{preferences.min_healthy_percentage}%", :reset, "\n",
      "  Max healthy: ", :bright, "#{preferences.max_healthy_percentage}%", :reset, "\n",
      "  Instance warmup: ", :bright, "#{preferences.instance_warmup}s", :reset
    ])

    case AwsAutoscaling.start_instance_refresh(asg_name, preferences, strategy: strategy) do
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

  defp resolve_availability(nil), do: %{min_healthy_percentage: 100, max_healthy_percentage: 110}
  defp resolve_availability(name) do
    case Map.fetch(@availability_presets, name) do
      {:ok, preset} -> preset
      :error -> Mix.raise("Invalid --availability value '#{name}'. Must be one of: #{@availability_presets |> Map.keys() |> Enum.join(", ")}")
    end
  end

  defp availability_label(%{min_healthy_percentage: min, max_healthy_percentage: max}) when min >= 100 and max > 100 do
    "Launch before terminating"
  end

  defp availability_label(_preferences), do: "Terminate and launch"

  defp wait_for_refresh(asg_name, refresh_id) do
    DeployEx.TUI.Progress.run_stream(
      "Instance Refresh",
      fn caller ->
        poll_refresh_status(asg_name, refresh_id, caller)
      end
    )
  end

  defp poll_refresh_status(asg_name, refresh_id, tui_pid) do
    case AwsAutoscaling.describe_instance_refreshes(asg_name, refresh_ids: [refresh_id]) do
      {:ok, [%{status: "Successful"} | _]} ->
        DeployEx.TUI.Progress.update_progress(tui_pid, 1.0, "Instance refresh completed successfully!")
        :ok

      {:ok, [%{status: "Failed", status_reason: reason} | _]} ->
        {:error, ErrorMessage.internal_server_error("Instance refresh failed: #{reason}")}

      {:ok, [%{status: "Cancelled"} | _]} ->
        {:error, ErrorMessage.internal_server_error("Instance refresh was cancelled")}

      {:ok, [%{status: status, percentage_complete: percent} | _]} ->
        ratio = (percent || 0) / 100
        DeployEx.TUI.Progress.update_progress(tui_pid, ratio, "#{status} (#{percent || 0}%)")
        Process.sleep(10_000)
        poll_refresh_status(asg_name, refresh_id, tui_pid)

      {:ok, []} ->
        {:error, ErrorMessage.not_found("Refresh not found")}

      {:error, error} ->
        {:error, error}
    end
  end
end
