defmodule Mix.Tasks.DeployEx.Instance.Health do
  use Mix.Task

  @shortdoc "Shows health status of EC2 instances"
  @moduledoc """
  Displays health and status information for EC2 instances.

  ## Example
  ```bash
  mix deploy_ex.instance.health
  mix deploy_ex.instance.health --qa
  mix deploy_ex.instance.health my_app
  mix deploy_ex.instance.health my_app --qa
  ```

  ## Options
  - `--qa` - Show only QA instances
  - `--all` - Show all instances including QA (default excludes QA)
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)
      opts = Map.new(opts)

      app_filter = case extra_args do
        [app_name | _] -> app_name
        [] -> nil
      end

      with {:ok, instances} <- fetch_instances(opts),
           {:ok, health_statuses} <- fetch_health_statuses(instances, opts) do
        instances
        |> filter_by_app(app_filter)
        |> filter_by_qa_mode(opts)
        |> display_instances(health_statuses, opts)
      else
        {:error, error} ->
          Mix.raise("Failed to fetch instances: #{inspect(error)}")
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [q: :qa, a: :all],
      switches: [
        qa: :boolean,
        all: :boolean
      ]
    )
  end

  defp fetch_instances(opts) do
    resource_group = DeployEx.Config.aws_resource_group()
    DeployEx.AwsMachine.find_instances_by_tags([{"Group", resource_group}], Map.to_list(opts))
  end

  defp fetch_health_statuses(instances, opts) do
    region = opts[:region] || DeployEx.Config.aws_region()
    instance_ids = Enum.map(instances, & &1["instanceId"])

    if Enum.empty?(instance_ids) do
      {:ok, %{}}
    else
      ExAws.EC2.describe_instance_status(instance_ids: instance_ids, include_all_instances: true)
      |> ExAws.request(region: region)
      |> handle_health_response()
    end
  end

  defp handle_health_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeInstanceStatusResponse" => %{"instanceStatusSet" => status_set}} ->
        statuses = parse_status_set(status_set)
        {:ok, statuses}

      _ ->
        {:ok, %{}}
    end
  end

  defp handle_health_response({:error, _} = error), do: error

  defp parse_status_set(nil), do: %{}
  defp parse_status_set(%{"item" => items}) when is_list(items) do
    Map.new(items, fn item ->
      {item["instanceId"], parse_status_item(item)}
    end)
  end
  defp parse_status_set(%{"item" => item}) when is_map(item) do
    %{item["instanceId"] => parse_status_item(item)}
  end
  defp parse_status_set(_), do: %{}

  defp parse_status_item(item) do
    %{
      system_status: get_in(item, ["systemStatus", "status"]),
      instance_status: get_in(item, ["instanceStatus", "status"]),
      system_details: parse_status_details(get_in(item, ["systemStatus", "details", "item"])),
      instance_details: parse_status_details(get_in(item, ["instanceStatus", "details", "item"]))
    }
  end

  defp parse_status_details(nil), do: []
  defp parse_status_details(items) when is_list(items) do
    Enum.map(items, fn item -> {item["name"], item["status"]} end)
  end
  defp parse_status_details(item) when is_map(item) do
    [{item["name"], item["status"]}]
  end

  defp filter_by_app(instances, nil), do: instances
  defp filter_by_app(instances, app_name) do
    Enum.filter(instances, fn instance ->
      tags = get_tags(instance)
      instance_group = tags["InstanceGroup"] || ""
      String.contains?(instance_group, app_name)
    end)
  end

  defp filter_by_qa_mode(instances, %{qa: true}) do
    Enum.filter(instances, &qa_node?/1)
  end
  defp filter_by_qa_mode(instances, %{all: true}), do: instances
  defp filter_by_qa_mode(instances, _opts) do
    Enum.reject(instances, &qa_node?/1)
  end

  defp qa_node?(instance) do
    tags = get_tags(instance)
    tags["QaNode"] === "true"
  end

  defp get_tags(instance) do
    case instance["tagSet"]["item"] do
      items when is_list(items) ->
        Map.new(items, fn %{"key" => k, "value" => v} -> {k, v} end)
      item when is_map(item) ->
        %{item["key"] => item["value"]}
      _ ->
        %{}
    end
  end

  defp display_instances([], _health_statuses, _opts) do
    Mix.shell().info([:yellow, "No instances found"])
  end

  defp display_instances(instances, health_statuses, opts) do
    grouped = Enum.group_by(instances, fn instance ->
      tags = get_tags(instance)
      tags["InstanceGroup"] || "unknown"
    end)

    Mix.shell().info("")

    if opts[:qa] do
      Mix.shell().info([:bright, "QA Instances", :reset])
    else
      Mix.shell().info([:bright, "Instance Health Status", :reset])
    end

    Mix.shell().info("")

    Enum.each(Enum.sort(grouped), fn {group, group_instances} ->
      Mix.shell().info([:cyan, "#{group}", :reset])

      Enum.each(group_instances, fn instance ->
        health = Map.get(health_statuses, instance["instanceId"], %{})
        display_instance(instance, health)
      end)

      Mix.shell().info("")
    end)

    total = length(instances)
    running = Enum.count(instances, fn i -> i["instanceState"]["name"] === "running" end)
    Mix.shell().info([:bright, "Total: #{total} instances (#{running} running)"])
  end

  defp display_instance(instance, health) do
    tags = get_tags(instance)
    name = tags["Name"] || "unnamed"
    instance_id = instance["instanceId"]
    state = instance["instanceState"]["name"]
    ip = instance["ipAddress"] || "no ip"
    instance_type = instance["instanceType"]

    state_color = case state do
      "running" -> :green
      "pending" -> :yellow
      "stopping" -> :yellow
      "stopped" -> :red
      "terminated" -> :red
      _ -> :reset
    end

    qa_badge = if tags["QaNode"] === "true", do: [:magenta, " [QA]", :reset], else: []

    Mix.shell().info([
      "  ", state_color, "●", :reset,
      " ", name] ++ qa_badge ++ [
      :reset, "\n",
      "    ", :faint, "ID: ", :reset, instance_id,
      :faint, " | Type: ", :reset, instance_type,
      :faint, " | IP: ", :reset, ip,
      :faint, " | State: ", :reset, state_color, state, :reset
    ])

    display_health_status(health)

    if tags["TargetSha"] do
      Mix.shell().info([
        "    ", :faint, "SHA: ", :reset, String.slice(tags["TargetSha"], 0, 7)
      ])
    end
  end

  defp display_health_status(%{system_status: system, instance_status: instance}) do
    system_color = health_color(system)
    instance_color = health_color(instance)

    Mix.shell().info([
      "    ", :faint, "Health: ", :reset,
      "System: ", system_color, system || "N/A", :reset,
      :faint, " | ", :reset,
      "Instance: ", instance_color, instance || "N/A", :reset
    ])
  end
  defp display_health_status(_), do: :ok

  defp health_color("ok"), do: :green
  defp health_color("initializing"), do: :yellow
  defp health_color("impaired"), do: :red
  defp health_color("insufficient-data"), do: :yellow
  defp health_color("not-applicable"), do: :faint
  defp health_color(_), do: :reset
end
