defmodule Mix.Tasks.DeployEx.Instance.Status do
  use Mix.Task

  alias DeployEx.{AwsAutoscaling, AwsLoadBalancer, AwsMachine}

  @shortdoc "Displays instance status for an application"
  @moduledoc """
  Displays the current status of instances for an application including:
  - Autoscaling status (if enabled)
  - Instance state and health
  - Load balancer attachment and health
  - Elastic IP or public/private IP addresses
  - Instance tags

  ## Usage

      mix deploy_ex.instance.status <app_name>

  ## Examples

      mix deploy_ex.instance.status cfx_web
      mix deploy_ex.instance.status my_app_redis

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
      [] -> Mix.raise("Application name is required. Usage: mix deploy_ex.instance.status <app_name>")
    end

    environment = Keyword.get(opts, :environment, Mix.env() |> to_string())

    with :ok <- DeployExHelpers.check_in_umbrella() do
      Mix.shell().info([:blue, "Fetching instance status for #{app_name}..."])

      display_autoscaling_status(app_name, environment)
      display_instance_details(app_name, environment)
    end
  end

  defp display_autoscaling_status(app_name, environment) do
    case AwsAutoscaling.find_asg_by_prefix(app_name, environment) do
      {:ok, []} ->
        asg_name = AwsAutoscaling.build_asg_name(app_name, environment)
        case AwsAutoscaling.describe_auto_scaling_group(asg_name) do
          {:ok, asg_data} ->
            display_asg_info(asg_data, asg_name)

          {:error, %ErrorMessage{code: :not_found}} ->
            Mix.shell().info([
              :green, "\n",
              "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
              :cyan, "Autoscaling: ", :yellow, "Not Enabled\n",
              "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            ])

          {:error, _error} ->
            Mix.shell().info([
              :green, "\n",
              "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
              :cyan, "Autoscaling: ", :yellow, "Not Enabled\n",
              "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
            ])
        end

      {:ok, asgs} ->
        Enum.each(asgs, fn asg_data ->
          display_asg_info(asg_data, asg_data.name)
        end)

      {:error, _error} ->
        Mix.shell().info([
          :green, "\n",
          "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
          :cyan, "Autoscaling: ", :yellow, "Not Enabled\n",
          "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        ])
    end
  end

  defp display_asg_info(asg_data, asg_name) do
    Mix.shell().info([
      :green, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
      :cyan, "Autoscaling: ", :green, "Enabled\n",
      :reset, "  Group: ", :bright, asg_name, :reset, "\n",
      "  Desired: ", :bright, "#{asg_data.desired_capacity}", :reset,
      " | Min: #{asg_data.min_size} | Max: #{asg_data.max_size}\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    ])
  end

  defp display_instance_details(app_name, environment) do
    tag_filters = [
      {"InstanceGroup", ~r/#{Regex.escape(app_name)}/},
      {"Environment", environment}
    ]

    with {:ok, instances} <- AwsMachine.find_instances_by_tags(tag_filters),
         {:ok, eips} <- fetch_elastic_ips(),
         {:ok, target_groups} <- AwsLoadBalancer.find_target_groups_by_app(app_name) do

      lb_health_map = build_lb_health_map(target_groups)

      if Enum.empty?(instances) do
        Mix.shell().info([:yellow, "\nNo instances found for #{app_name} in #{environment}"])
      else
        Mix.shell().info([
          :cyan, "\nInstances (", :bright, "#{length(instances)}", :reset, :cyan, "):\n"
        ])

        instances
        |> Enum.map(&AwsMachine.parse_instance_info/1)
        |> Enum.sort_by(& &1.tags["Name"])
        |> Enum.each(fn instance ->
          display_instance(instance, eips, lb_health_map, target_groups)
        end)
      end

      Mix.shell().info([
        :green, "\n",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
      ])
    else
      {:error, %ErrorMessage{message: message}} ->
        Mix.shell().error([:red, "\nError: #{message}"])

      {:error, error} ->
        Mix.shell().error([:red, "\nError fetching instance details: #{inspect(error)}"])
    end
  end

  defp display_instance(instance, eips, lb_health_map, target_groups) do
    state_color = case instance.state do
      "running" -> :green
      "pending" -> :yellow
      "stopped" -> :red
      _ -> :yellow
    end

    eip_info = find_eip_for_instance(eips, instance.instance_id)

    Mix.shell().info([
      :bright, "\n  #{instance.tags["Name"] || instance.instance_id}\n", :reset,
      "  ├─ ", :cyan, "Instance ID: ", :reset, instance.instance_id, "\n",
      "  ├─ ", :cyan, "State: ", state_color, instance.state, :reset, "\n",
      "  ├─ ", :cyan, "Type: ", :reset, "#{instance.instance_type}\n"
    ])

    display_ip_info(instance, eip_info)
    display_lb_health(instance.instance_id, lb_health_map, target_groups)
    display_tags(instance.tags)
  end

  defp display_ip_info(instance, eip_info) do
    ip_lines = []

    ip_lines = if eip_info do
      ip_lines ++ [["  ├─ ", :cyan, "Elastic IP: ", :green, eip_info.public_ip, :reset, " (", eip_info.allocation_id, ")\n"]]
    else
      ip_lines
    end

    ip_lines = if instance.public_ip do
      ip_lines ++ [["  ├─ ", :cyan, "Public IP: ", :reset, instance.public_ip, "\n"]]
    else
      ip_lines
    end

    ip_lines = if instance.private_ip do
      ip_lines ++ [["  ├─ ", :cyan, "Private IP: ", :reset, instance.private_ip, "\n"]]
    else
      ip_lines
    end

    ip_lines = if instance.ipv6 do
      ip_lines ++ [["  ├─ ", :cyan, "IPv6: ", :reset, instance.ipv6, "\n"]]
    else
      ip_lines
    end

    Enum.each(ip_lines, &Mix.shell().info/1)
  end

  defp display_lb_health(instance_id, lb_health_map, target_groups) do
    if Enum.empty?(target_groups) do
      Mix.shell().info(["  ├─ ", :cyan, "Load Balancer: ", :yellow, "Not attached\n"])
    else
      Enum.each(target_groups, fn tg ->
        health = Map.get(lb_health_map, {tg.arn, instance_id})

        {health_color, health_text} = case health do
          %{state: "healthy"} -> {:green, "healthy"}
          %{state: "unhealthy", reason: reason} -> {:red, "unhealthy (#{reason})"}
          %{state: "initial"} -> {:yellow, "initial"}
          %{state: "draining"} -> {:yellow, "draining"}
          nil -> {:yellow, "not registered"}
        end

        Mix.shell().info([
          "  ├─ ", :cyan, "Target Group: ", :reset, tg.name, " - ", health_color, health_text, :reset, "\n"
        ])
      end)
    end
  end

  defp display_tags(tags) do
    sorted_tags = Enum.sort_by(tags, fn {key, _} -> key end)

    if Enum.empty?(sorted_tags) do
      :ok
    else
      Mix.shell().info(["  └─ ", :cyan, "Tags:\n"])
      sorted_tags
      |> Enum.with_index()
      |> Enum.each(fn {{key, value}, idx} ->
        prefix = if idx === length(sorted_tags) - 1, do: "     └─ ", else: "     ├─ "
        Mix.shell().info([prefix, :bright, key, :reset, ": ", value, "\n"])
      end)
    end
  end

  defp fetch_elastic_ips do
    region = DeployEx.Config.aws_region()

    %ExAws.Operation.Query{
      path: "/",
      params: %{
        "Action" => "DescribeAddresses",
        "Version" => "2016-11-15"
      },
      service: :ec2
    }
    |> ExAws.request(region: region)
    |> handle_eip_response()
  end

  defp handle_eip_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"DescribeAddressesResponse" => %{"addressesSet" => %{"item" => items}}} when is_list(items) ->
        {:ok, Enum.map(items, &parse_eip/1)}

      %{"DescribeAddressesResponse" => %{"addressesSet" => %{"item" => item}}} when is_map(item) ->
        {:ok, [parse_eip(item)]}

      %{"DescribeAddressesResponse" => %{"addressesSet" => nil}} ->
        {:ok, []}

      _ ->
        {:ok, []}
    end
  end

  defp handle_eip_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error fetching elastic IPs",
      %{error_body: body}
    ])}
  end

  defp handle_eip_response({:error, error}) do
    {:error, ErrorMessage.failed_dependency("AWS request failed", %{error: inspect(error)})}
  end

  defp parse_eip(item) do
    %{
      public_ip: item["publicIp"],
      allocation_id: item["allocationId"],
      instance_id: item["instanceId"],
      association_id: item["associationId"],
      domain: item["domain"],
      private_ip: item["privateIpAddress"]
    }
  end

  defp find_eip_for_instance(eips, instance_id) do
    Enum.find(eips, fn eip -> eip.instance_id === instance_id end)
  end

  defp build_lb_health_map(target_groups) do
    target_groups
    |> Enum.reduce(%{}, fn tg, acc ->
      case AwsLoadBalancer.describe_target_health(tg.arn) do
        {:ok, targets} ->
          Enum.reduce(targets, acc, fn target, inner_acc ->
            Map.put(inner_acc, {tg.arn, target.id}, target)
          end)

        {:error, _} ->
          acc
      end
    end)
  end
end
