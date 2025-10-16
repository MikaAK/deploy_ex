defmodule DeployEx.AwsMachine do
  def start(region \\ DeployEx.Config.aws_region(), instance_ids) do
    instance_ids
      |> ExAws.EC2.start_instances()
      |> ex_aws_request(region)
      |> handle_describe_response
  end

  def stop(region \\ DeployEx.Config.aws_region(), instance_ids) do
    instance_ids
      |> ExAws.EC2.stop_instances()
      |> ex_aws_request(region)
      |> handle_describe_response
  end

  def wait_for_started(region \\ DeployEx.Config.aws_region(), instance_ids) do
    with {:ok, instances} <- find_instances_by_id(region, instance_ids) do
      cond do
        Enum.all?(instances, &instance_started?/1) ->
          :ok

        Enum.any?(instances, &(instance_pending?(&1) or instance_stopped?(&1))) ->
          Process.sleep(500)

          wait_for_started(region, instance_ids)

        true ->
          {:error, ErrorMessage.failed_dependency(
            "instance not started but not pending either",
            %{instance_ids: instance_ids}
          )}
      end
    end
  end

  def wait_for_stopped(region \\ DeployEx.Config.aws_region(), instance_ids) do
    with {:ok, instances} <- find_instances_by_id(region, instance_ids) do
      cond do
        Enum.all?(instances, &instance_stopped?/1) ->
          :ok

        Enum.any?(instances, &(instance_pending?(&1) or instance_started?(&1))) ->
          Process.sleep(500)

          wait_for_stopped(region, instance_ids)

        true ->
          {:error, ErrorMessage.failed_dependency(
            "instance not stopped but not pending either",
            %{instance_ids: instance_ids}
          )}
      end
    end
  end

  defp instance_pending?(instance) do
    instance["instanceState"]["name"] in ["pending", "stopping", "starting"]
  end

  defp instance_started?(instance) do
    instance["instanceState"]["name"] in ["started", "running"]
  end

  defp instance_stopped?(instance) do
    instance["instanceState"]["name"] === "stopped"
  end

  def find_instances_by_id(region \\ DeployEx.Config.aws_region(), instance_ids) do
    with {:ok, instances} <- fetch_instances(region) do
      case filter_by_instance_id(instances, instance_ids) do
        [] -> {:error, ErrorMessage.not_found("no aws instances found with those instance ids")}
        instances -> {:ok, instances}
      end
    end
  end

  def fetch_instance_ids_by_tag(region \\ DeployEx.Config.aws_region(), tag_name, tag) do
    with {:ok, instances} <- fetch_instances_by_tag(region, tag_name, tag) do
      {:ok, Map.new(instances, &{find_instance_name(&1), &1["instanceId"]})}
    end
  end

  defp find_instance_name(%{"tagSet" => %{"item" => items}}) do
    Enum.find_value(items, fn %{"key" => key, "value" => value} ->
      if key === "Name" do
        value
      end
    end)
  end

  def fetch_instances_by_tag(region \\ DeployEx.Config.aws_region(), tag_name, tag) do
    with {:ok, instances} <- fetch_instances(region) do
      case filter_by_tag(instances, tag_name, tag) do
        [] -> {:error, ErrorMessage.not_found("no aws instances found with the tag #{tag_name} of #{tag}")}

        tags -> {:ok, tags}
      end
    end
  end

  def fetch_instances(region) do
    ExAws.EC2.describe_instances()
      |> ex_aws_request(region)
      |> handle_describe_response
  end

  defp ex_aws_request(request_struct, nil) do
    ExAws.request(request_struct)
  end

  defp ex_aws_request(request_struct, region) do
    ExAws.request(request_struct, region: region)
  end

  defp handle_describe_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error with fetching from aws",
      %{error_body: body}
    ])}
  end

  defp handle_describe_response({:ok, %{body: body}}) do
    case XmlToMap.naive_map(body) do
      %{"StopInstancesResponse" => %{"instancesSet" => %{"item" => item}}} ->
        {:ok, item}

      %{"StartInstancesResponse" => %{"instancesSet" => %{"item" => item}}} ->
        {:ok, item}

      %{"DescribeInstancesResponse" => %{"reservationSet" => %{"item" => items}}} when is_list(items) ->
        {:ok, Enum.map(items, fn %{"instancesSet" => %{"item" => item}} -> item end)}

      %{"DescribeInstancesResponse" => %{"reservationSet" => %{"item" => item}}} ->
        {:ok, [item["instancesSet"]["item"]]}

      %{"DescribeInstancesResponse" => %{"reservationSet" => nil}} ->
        {:ok, []}

      structure ->
        {:error, ErrorMessage.bad_request(
          "couldn't parse the structure from aws correctly",
          %{structure: structure}
        )}
    end
  end

  defp filter_by_tag(instances, tag_name, tag_value) do
    Enum.filter(instances, fn %{"tagSet" => %{"item" => tags}} ->
       Enum.any?(tags, fn
        %{"key" => ^tag_name, "value" => ^tag_value} -> true
        %{"key" => ^tag_name, "value" => value} when is_list(tag_value) -> value in tag_value
        %{"key" => ^tag_name, "value" => value} when is_struct(tag_value, Regex) -> Regex.match?(tag_value, value)
        _ -> false
      end)
    end)
  end

  defp filter_by_instance_id(instances, instance_ids) do
    Enum.filter(instances, &(&1["instanceId"] in instance_ids))
  end

  @doc """
  Finds a suitable jump server from available EC2 instances.
  Returns {:ok, ip} or {:error, reason}
  """
  def find_jump_server(project_name, opts \\ []) do
    with {:ok, instances} <- DeployEx.AwsMachine.fetch_instance_groups(project_name, opts) do
      server_ips = Enum.flat_map(instances, fn {name, instances} ->
        Enum.map(instances, fn %{ip: ip, ipv6: ipv6, name: server_name} -> {ip, ipv6, "#{name} (#{server_name})"} end)
      end)

      case server_ips do
        [{ip, ipv6, _}] -> {:ok, {ip, ipv6}}  # Single server case
        servers when servers !== [] ->
          [choice] = DeployExHelpers.prompt_for_choice(Enum.map(servers, fn {_, _, name} -> name end))
          {ip, ipv6, _} = Enum.find(servers, fn {_, _, name} -> name === choice end)
          {:ok, {ip, ipv6}}
        _ -> {:error, ErrorMessage.not_found("No jump servers found")}
      end
    end
  end

  def fetch_instance_groups(project_name, opts \\ []) do
    resource_group = opts[:resource_group] ||
                     "#{DeployEx.Utils.upper_title_case(project_name)} Backend"

    with {:ok, instances} <- fetch_instances_by_tag("Group", resource_group) do
      {:ok, instances
        |> Stream.map(fn instance_data ->
          instance_data
            |> Map.put("InstanceGroupTag", Enum.find_value(instance_data["tagSet"]["item"], fn
              %{"key" => "InstanceGroup", "value" => value} -> value
              _ -> false
            end))
            |> Map.put("NameTag", Enum.find_value(instance_data["tagSet"]["item"], fn
              %{"key" => "Name", "value" => value} -> value
              _ -> false
            end))
        end)
        |> Stream.reject(&is_nil(&1["InstanceGroupTag"]))
        |> Stream.filter(&(&1["instanceState"]["name"] === "running"))
        |> Enum.group_by(&(&1["InstanceGroupTag"]), &%{
          name: &1["NameTag"],
          ip: &1["ipAddress"],
          ipv6: &1["ipv6Address"]
        })}
    end
  end

  def find_instance_details(project_name, app_name, opts \\ []) do
    with {:ok, instance_groups} <- fetch_instance_groups(project_name, opts) do
      case Enum.find_value(instance_groups, fn {group, values} -> if group =~ app_name, do: values end) do
        nil ->
          {:error, ErrorMessage.not_found(
            "no app names found with #{app_name}",
            %{app_names: Map.keys(instance_groups)}
          )}

        instances -> {:ok, instances}
      end
    end
  end

  def find_instance_ips(project_name, app_name, opts \\ []) do
    case find_instance_details(project_name, app_name, opts) do
      {:ok, [%{ip: ip, ipv6: ipv6}]} -> {:ok, [ipv6 || ip]}

      {:ok, instances} -> {:ok, Enum.map(instances, &(&1[:ipv6] || &1[:ip]))}

      e -> e
    end
  end
end
