defmodule Mix.Tasks.DeployEx.Autoscale.RefreshStatus do
  use Mix.Task

  alias DeployEx.AwsAutoscaling

  @shortdoc "Shows the status of instance refreshes for an autoscaling group"
  @moduledoc """
  Displays the status of instance refreshes for an Auto Scaling Group.

  ## Usage

      mix deploy_ex.autoscale.refresh_status <app_name>

  ## Examples

      mix deploy_ex.autoscale.refresh_status my_app
      mix deploy_ex.autoscale.refresh_status my_app --all

  ## Options

  - `--environment` or `-e` - Environment name (default: Mix.env())
  - `--all` or `-a` - Show all refreshes (default: only active/recent)
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, remaining_args} = OptionParser.parse!(args,
      aliases: [e: :environment, a: :all],
      switches: [environment: :string, all: :boolean]
    )

    app_name = case remaining_args do
      [name | _] -> name
      [] -> Mix.raise("Application name is required. Usage: mix deploy_ex.autoscale.refresh_status <app_name>")
    end

    environment = Keyword.get(opts, :environment, Mix.env() |> to_string())
    show_all = Keyword.get(opts, :all, false)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      Mix.shell().info([:blue, "Fetching instance refresh status for #{app_name}..."])

      case AwsAutoscaling.find_asg_by_prefix(app_name, environment) do
        {:ok, []} ->
          asg_name = AwsAutoscaling.build_asg_name(app_name, environment)
          fetch_and_display_refreshes(asg_name, show_all)

        {:ok, asgs} ->
          Enum.each(asgs, fn asg ->
            fetch_and_display_refreshes(asg.name, show_all)
          end)

        {:error, error} ->
          Mix.shell().error([:red, "\nError finding autoscaling groups: #{inspect(error)}\n"])
      end
    end
  end

  defp fetch_and_display_refreshes(asg_name, show_all) do
    case AwsAutoscaling.describe_instance_refreshes(asg_name) do
      {:ok, []} ->
        Mix.shell().info([:yellow, "\nNo instance refreshes found for #{asg_name}."])

      {:ok, refreshes} ->
        display_refreshes(refreshes, asg_name, show_all)

      {:error, %ErrorMessage{code: :not_found}} ->
        Mix.raise("Autoscaling group '#{asg_name}' not found")

      {:error, error} ->
        Mix.raise("Error fetching refresh status: #{inspect(error)}")
    end
  end

  defp display_refreshes(refreshes, asg_name, show_all) do
    refreshes_to_show = if show_all do
      refreshes
    else
      Enum.filter(refreshes, fn r ->
        r.status in ["Pending", "InProgress", "Cancelling"] or
        recent_refresh?(r)
      end)
    end

    if Enum.empty?(refreshes_to_show) do
      Mix.shell().info([:yellow, "\nNo active or recent instance refreshes for #{asg_name}."])
      Mix.shell().info("Use --all to see all historical refreshes.")
    else
      Mix.shell().info([
        :green, "\n",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
        :bright, "Instance Refreshes: ", :normal, asg_name, "\n",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
      ])

      instances = fetch_asg_instances(asg_name)

      active_refreshes = Enum.filter(refreshes_to_show, fn r ->
        r.status in ["Pending", "InProgress"]
      end)

      warming_instance_ids = extract_warming_instance_ids(active_refreshes)

      Enum.each(refreshes_to_show, &display_refresh/1)

      if not Enum.empty?(active_refreshes) and not Enum.empty?(instances) do
        display_instances(instances, warming_instance_ids)
      end

      Mix.shell().info([
        :green,
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
      ])
    end
  end

  defp display_refresh(refresh) do
    status_color = case refresh.status do
      "Successful" -> :green
      "Failed" -> :red
      "Cancelled" -> :yellow
      "InProgress" -> :cyan
      "Pending" -> :blue
      _ -> :reset
    end

    Mix.shell().info([
      "\n", status_color, "● ", refresh.status, :reset, " - ", refresh.refresh_id
    ])

    Mix.shell().info([
      "  Progress: ", :bright, "#{refresh.percentage_complete || 0}%", :reset
    ])

    if refresh.start_time do
      Mix.shell().info(["  Started: ", format_time(refresh.start_time)])
    end

    if refresh.end_time do
      Mix.shell().info(["  Ended: ", format_time(refresh.end_time)])
    end

    if refresh.status_reason do
      Mix.shell().info(["  Reason: ", refresh.status_reason])
    end

    if refresh.instances_to_update do
      Mix.shell().info(["  Instances to update: ", to_string(refresh.instances_to_update)])
    end
  end

  defp fetch_asg_instances(asg_name) do
    case AwsAutoscaling.describe_auto_scaling_group(asg_name) do
      {:ok, asg} -> asg.instances
      _ -> []
    end
  end

  defp extract_warming_instance_ids(active_refreshes) do
    active_refreshes
    |> Enum.flat_map(fn refresh ->
      if is_nil(refresh.status_reason) do
        []
      else
        Regex.scan(~r/i-[0-9a-f]+/, refresh.status_reason) |> List.flatten()
      end
    end)
    |> MapSet.new()
  end

  defp display_instances(instances, warming_instance_ids) do
    Mix.shell().info([
      "\n  ", :bright, "Instances:", :reset
    ])

    instances
    |> Enum.sort_by(& &1.lifecycle_state)
    |> Enum.each(fn instance ->
      warming? = MapSet.member?(warming_instance_ids, instance.instance_id)

      state_color = cond do
        String.starts_with?(instance.lifecycle_state, "Terminating") -> :red
        warming? -> :cyan
        instance.lifecycle_state === "InService" -> :green
        String.starts_with?(instance.lifecycle_state, "Pending") -> :cyan
        true -> :yellow
      end

      label = cond do
        String.starts_with?(instance.lifecycle_state, "Terminating") -> " [spinning down]"
        warming? -> " [warming up]"
        String.starts_with?(instance.lifecycle_state, "Pending") -> " [launching]"
        true -> ""
      end

      type_info = if instance.instance_type, do: " #{instance.instance_type}", else: ""

      Mix.shell().info([
        "    ", state_color, "● ", :reset,
        instance.instance_id,
        :faint, " (", instance.lifecycle_state, " / ", instance.health_status || "Unknown", ")", :reset,
        :faint, type_info, :reset,
        :faint, " ", instance.availability_zone || "", :reset,
        state_color, label, :reset
      ])
    end)
  end

  defp recent_refresh?(refresh) do
    if is_nil(refresh.end_time) do
      true
    else
      case DateTime.from_iso8601(refresh.end_time) do
        {:ok, dt, _} ->
          DateTime.diff(DateTime.utc_now(), dt, :hour) < 24

        _ -> false
      end
    end
  end

  defp format_time(iso_time) do
    case DateTime.from_iso8601(iso_time) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

      _ ->
        iso_time
    end
  end
end
