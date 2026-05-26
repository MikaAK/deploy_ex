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
      mix deploy_ex.autoscale.refresh_status my_app --wait
      mix deploy_ex.autoscale.refresh_status my_app --wait --timeout 1200 --poll-interval 15

  ## Options

  - `--environment` or `-e` - Environment name (default: Mix.env())
  - `--all` or `-a` - Show all refreshes (default: only active/recent)
  - `--wait` or `-w` - Block until all active refreshes reach a terminal state.
    Exits non-zero if any refresh ends as Failed or Cancelled.
  - `--timeout` - Max seconds to wait when `--wait` is set (default: 1800)
  - `--poll-interval` - Seconds between polls when `--wait` is set (default: 10)
  """

  @default_poll_interval 10
  @default_timeout 1_800

  @active_statuses ~w[Pending InProgress Cancelling]
  @waiting_statuses ~w[Pending InProgress]
  @terminal_failure_statuses ~w[Failed Cancelled]

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, remaining_args} = OptionParser.parse!(args,
      aliases: [e: :environment, a: :all, w: :wait],
      switches: [
        environment: :string,
        all: :boolean,
        wait: :boolean,
        timeout: :integer,
        poll_interval: :integer
      ]
    )

    app_name = case remaining_args do
      [name | _] -> name
      [] -> Mix.raise("Application name is required. Usage: mix deploy_ex.autoscale.refresh_status <app_name>")
    end

    environment = Keyword.get(opts, :environment, Mix.env() |> to_string())
    show_all = Keyword.get(opts, :all, false)
    wait? = Keyword.get(opts, :wait, false)
    timeout_secs = Keyword.get(opts, :timeout, @default_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)

    with :ok <- DeployExHelpers.check_valid_project() do
      Mix.shell().info(IO.ANSI.format([:blue, "Fetching instance refresh status for #{app_name}..."], true))

      asg_names = resolve_asg_names(app_name, environment)

      Enum.each(asg_names, fn asg_name ->
        fetch_and_display_refreshes(asg_name, show_all)
      end)

      if wait? do
        wait_for_all(asg_names, timeout_secs, poll_interval)
      end
    end
  end

  defp resolve_asg_names(app_name, environment) do
    case AwsAutoscaling.find_asg_by_prefix(app_name, environment) do
      {:ok, []} ->
        [AwsAutoscaling.build_asg_name(app_name, environment)]

      {:ok, asgs} ->
        Enum.map(asgs, & &1.name)

      {:error, error} ->
        Mix.shell().error(IO.ANSI.format([:red, "\nError finding autoscaling groups: #{inspect(error)}\n"], true))
        []
    end
  end

  defp fetch_and_display_refreshes(asg_name, show_all) do
    case AwsAutoscaling.describe_instance_refreshes(asg_name) do
      {:ok, []} ->
        Mix.shell().info(IO.ANSI.format([:yellow, "\nNo instance refreshes found for #{asg_name}."], true))

      {:ok, refreshes} ->
        display_refreshes(refreshes, asg_name, show_all)

      {:error, %ErrorMessage{code: :not_found}} ->
        Mix.raise("Autoscaling group '#{asg_name}' not found")

      {:error, error} ->
        Mix.raise("Error fetching refresh status: #{inspect(error)}")
    end
  end

  defp wait_for_all(asg_names, timeout_secs, poll_interval) do
    deadline = System.monotonic_time(:second) + timeout_secs

    results = Enum.map(asg_names, &wait_for_asg(&1, deadline, poll_interval))

    failures = collect_failures(results)
    timed_out? = any_still_waiting?(results)

    cond do
      timed_out? ->
        Mix.raise("Timed out after #{timeout_secs}s waiting for instance refreshes to finish")

      not Enum.empty?(failures) ->
        Enum.each(failures, &log_failed_refresh/1)
        Mix.raise("One or more instance refreshes did not complete successfully")

      true ->
        Mix.shell().info(IO.ANSI.format([
          :green, "\n✓ All instance refreshes completed successfully", :reset
        ], true))
    end
  end

  defp collect_failures(results) do
    Enum.flat_map(results, fn {asg_name, refreshes} ->
      refreshes
      |> Enum.filter(&(&1.status in @terminal_failure_statuses))
      |> Enum.map(fn refresh -> {asg_name, refresh} end)
    end)
  end

  defp any_still_waiting?(results) do
    Enum.any?(results, fn {_asg, refreshes} ->
      Enum.any?(refreshes, &(&1.status in @waiting_statuses))
    end)
  end

  defp log_failed_refresh({asg_name, refresh}) do
    reason_text =
      if refresh.status_reason, do: ": #{refresh.status_reason}", else: ""

    Mix.shell().error(IO.ANSI.format([
      :red, "✗ ", asg_name, " refresh ", refresh.refresh_id,
      " ended ", refresh.status, reason_text, :reset
    ], true))
  end

  defp wait_for_asg(asg_name, deadline, poll_interval) do
    case AwsAutoscaling.describe_instance_refreshes(asg_name) do
      {:ok, refreshes} ->
        tracked_ids =
          refreshes
          |> Enum.filter(&(&1.status in @active_statuses))
          |> Enum.map(& &1.refresh_id)

        if Enum.empty?(tracked_ids) do
          Mix.shell().info(IO.ANSI.format([
            :faint, "  (no active refreshes on ", asg_name, ", skipping wait)", :reset
          ], true))

          {asg_name, refreshes}
        else
          Mix.shell().info(IO.ANSI.format([
            :cyan, "\n⏳ Waiting for ", to_string(length(tracked_ids)),
            " refresh(es) on ", asg_name, "...", :reset
          ], true))

          final = poll_until_done(asg_name, tracked_ids, deadline, poll_interval)
          {asg_name, final}
        end

      {:error, error} ->
        Mix.shell().error(IO.ANSI.format([
          :red, "Failed to poll ", asg_name, ": ", inspect(error), :reset
        ], true))

        {asg_name, []}
    end
  end

  defp poll_until_done(asg_name, refresh_ids, deadline, poll_interval) do
    case AwsAutoscaling.describe_instance_refreshes(asg_name, refresh_ids: refresh_ids) do
      {:ok, refreshes} ->
        Enum.each(refreshes, &log_progress_line(asg_name, &1))

        active? = Enum.any?(refreshes, &(&1.status in @waiting_statuses))
        time_left = deadline - System.monotonic_time(:second)

        cond do
          not active? -> refreshes
          time_left <= 0 -> refreshes
          true ->
            :timer.sleep(poll_interval * 1000)
            poll_until_done(asg_name, refresh_ids, deadline, poll_interval)
        end

      {:error, error} ->
        Mix.shell().error(IO.ANSI.format([
          :red, "Poll error on ", asg_name, ": ", inspect(error), :reset
        ], true))

        :timer.sleep(poll_interval * 1000)
        if System.monotonic_time(:second) >= deadline do
          []
        else
          poll_until_done(asg_name, refresh_ids, deadline, poll_interval)
        end
    end
  end

  defp log_progress_line(asg_name, refresh) do
    color = status_color(refresh.status)
    pct = refresh.percentage_complete || 0

    Mix.shell().info(IO.ANSI.format([
      "  ", color, "● ", refresh.status, :reset,
      " ", refresh.refresh_id,
      :faint, " (", asg_name, ")", :reset,
      " — ", :bright, "#{pct}%", :reset
    ], true))
  end

  defp status_color("Successful"), do: :green
  defp status_color("Failed"), do: :red
  defp status_color("Cancelled"), do: :yellow
  defp status_color("Cancelling"), do: :yellow
  defp status_color("InProgress"), do: :cyan
  defp status_color("Pending"), do: :blue
  defp status_color(_), do: :reset

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
