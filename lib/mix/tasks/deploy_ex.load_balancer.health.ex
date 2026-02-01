defmodule Mix.Tasks.DeployEx.LoadBalancer.Health do
  use Mix.Task

  @shortdoc "Check load balancer health status for all instances"
  @moduledoc """
  Check and report load balancer health status for all instances.

  By default, QA nodes are excluded from the output. Use `--qa` to include them.

  ## Example
  ```bash
  mix deploy_ex.load_balancer.health
  mix deploy_ex.load_balancer.health my_app
  mix deploy_ex.load_balancer.health --qa
  mix deploy_ex.load_balancer.health --watch
  mix deploy_ex.load_balancer.health --json
  ```

  ## Options
  - `--qa` - Include QA nodes in health check (excluded by default)
  - `--watch, -w` - Continuously monitor (refresh every 5s)
  - `--json` - Output as JSON
  - `--quiet, -q` - Minimal output
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      app_name = List.first(extra_args)

      with {:ok, target_groups} <- find_target_groups(app_name, opts),
           {:ok, health_data} <- fetch_health_for_all(target_groups, opts) do
        health_data = maybe_filter_qa_nodes(health_data, opts)

        if opts[:watch] do
          watch_health(target_groups, opts)
        else
          output_health(health_data, opts)
        end
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [w: :watch, q: :quiet],
      switches: [
        qa: :boolean,
        watch: :boolean,
        json: :boolean,
        quiet: :boolean
      ]
    )
  end

  defp find_target_groups(nil, opts) do
    DeployEx.AwsLoadBalancer.describe_target_groups(opts)
  end

  defp find_target_groups(app_name, opts) do
    DeployEx.AwsLoadBalancer.find_target_groups_by_app(app_name, opts)
  end

  defp fetch_health_for_all(target_groups, opts) do
    health_data = Enum.map(target_groups, fn tg ->
      case DeployEx.AwsLoadBalancer.describe_target_health(tg.arn, opts) do
        {:ok, targets} ->
          enriched_targets = enrich_targets_with_instance_info(targets, opts)

          %{
            target_group_name: tg.name,
            target_group_arn: tg.arn,
            targets: enriched_targets
          }

        {:error, _} ->
          %{
            target_group_name: tg.name,
            target_group_arn: tg.arn,
            targets: []
          }
      end
    end)

    {:ok, health_data}
  end

  defp enrich_targets_with_instance_info(targets, _opts) do
    instance_ids = targets |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)

    instance_map = case DeployEx.AwsMachine.find_instances_by_id(instance_ids) do
      {:ok, instances} ->
        Map.new(instances, fn instance ->
          tags = get_instance_tags(instance)
          {instance["instanceId"], %{
            name: tags["Name"],
            is_qa_node: tags["QaNode"] === "true",
            app_name: tags["InstanceGroup"]
          }}
        end)

      _ ->
        %{}
    end

    Enum.map(targets, fn target ->
      instance_info = Map.get(instance_map, target.id, %{name: nil, is_qa_node: false, app_name: nil})

      Map.merge(target, %{
        instance_name: instance_info.name,
        is_qa_node: instance_info.is_qa_node,
        app_name: instance_info.app_name
      })
    end)
  end

  defp get_instance_tags(instance) do
    case instance["tagSet"] do
      %{"item" => items} when is_list(items) ->
        Map.new(items, fn %{"key" => k, "value" => v} -> {k, v} end)

      %{"item" => %{"key" => k, "value" => v}} ->
        %{k => v}

      _ ->
        %{}
    end
  end

  defp maybe_filter_qa_nodes(health_data, %{qa: true}), do: health_data
  defp maybe_filter_qa_nodes(health_data, _opts) do
    Enum.map(health_data, fn tg ->
      %{tg | targets: Enum.reject(tg.targets, & &1.is_qa_node)}
    end)
  end

  defp watch_health(target_groups, opts) do
    Mix.shell().info("Watching health status (Ctrl+C to stop)...\n")

    Stream.interval(5000)
    |> Stream.each(fn _ ->
      IO.write(IO.ANSI.clear())
      IO.write(IO.ANSI.home())

      {:ok, health_data} = fetch_health_for_all(target_groups, opts)
      health_data = maybe_filter_qa_nodes(health_data, opts)
      output_health(health_data, opts)
      IO.puts("\n" <> IO.ANSI.faint() <> "Refreshing every 5s... Press Ctrl+C to stop" <> IO.ANSI.reset())
    end)
    |> Stream.run()
  end

  defp output_health(health_data, %{json: true}) do
    json = health_data
    |> Enum.map(fn tg ->
      %{
        target_group_name: tg.target_group_name,
        target_group_arn: tg.target_group_arn,
        targets: Enum.map(tg.targets, fn t ->
          %{
            instance_id: t.id,
            instance_name: t.instance_name,
            port: t.port,
            state: t.state,
            reason: t.reason,
            is_qa_node: t.is_qa_node
          }
        end)
      }
    end)
    |> Jason.encode!(pretty: true)

    Mix.shell().info(json)
  end

  defp output_health(health_data, _opts) do
    Mix.shell().info("\nLoad Balancer Health Status")
    Mix.shell().info(String.duplicate("=", 40))

    summary = %{healthy: 0, unhealthy: 0, initial: 0, draining: 0, unused: 0}

    summary = Enum.reduce(health_data, summary, fn tg, acc ->
      Mix.shell().info(["\nTarget Group: ", :cyan, tg.target_group_name, :reset])

      if Enum.empty?(tg.targets) do
        Mix.shell().info("  (no targets)")
        acc
      else
        Enum.reduce(tg.targets, acc, fn target, inner_acc ->
          {symbol, color} = format_health_state(target.state)
          qa_label = if target.is_qa_node, do: [" ", :magenta, "[QA]", :reset], else: []

          Mix.shell().info([
            "  ", color, symbol, :reset, " ",
            target.instance_name || target.id || "unknown",
            " (", target.id || "?", ")",
            qa_label,
            " - ", color, target.state || "unknown", :reset
          ])

          if target.reason do
            Mix.shell().info(["    Reason: ", target.reason])
          end

          update_summary(inner_acc, target.state)
        end)
      end
    end)

    Mix.shell().info([
      "\n",
      :green, "Summary: ",
      :reset, "#{summary.healthy} healthy, ",
      :red, "#{summary.unhealthy} unhealthy",
      :reset, ", ",
      :yellow, "#{summary.initial} initializing",
      :reset, ", ",
      :blue, "#{summary.draining} draining"
    ])
  end

  defp format_health_state("healthy"), do: {"✓", :green}
  defp format_health_state("unhealthy"), do: {"✗", :red}
  defp format_health_state("initial"), do: {"⚠", :yellow}
  defp format_health_state("draining"), do: {"○", :blue}
  defp format_health_state("unused"), do: {"○", :faint}
  defp format_health_state(_), do: {"?", :faint}

  defp update_summary(summary, "healthy"), do: %{summary | healthy: summary.healthy + 1}
  defp update_summary(summary, "unhealthy"), do: %{summary | unhealthy: summary.unhealthy + 1}
  defp update_summary(summary, "initial"), do: %{summary | initial: summary.initial + 1}
  defp update_summary(summary, "draining"), do: %{summary | draining: summary.draining + 1}
  defp update_summary(summary, "unused"), do: %{summary | unused: summary.unused + 1}
  defp update_summary(summary, _), do: summary
end
