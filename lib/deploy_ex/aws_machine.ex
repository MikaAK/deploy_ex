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
    with {:ok, instances} <- fetch_aws_instances(region) do
      case filter_by_instance_id(instances, instance_ids) do
        [] -> {:error, ErrorMessage.not_found("no aws instances found with those instance ids")}
        instances -> {:ok, instances}
      end
    end
  end

  def fetch_instance_ids_by_tag(region \\ DeployEx.Config.aws_region(), tag_name, tag) do
    with {:ok, instances} <- fetch_aws_instances_by_tag(region, tag_name, tag) do
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

  def fetch_aws_instances_by_tag(region \\ DeployEx.Config.aws_region(), tag_name, tag) do
    with {:ok, instances} <- fetch_aws_instances(region) do
      case filter_by_tag(instances, tag_name, tag) do
        [] -> {:error, ErrorMessage.not_found("no aws instances found with the tag #{tag_name} of #{tag}")}

        tags -> {:ok, tags}
      end
    end
  end

  def fetch_aws_instances(region) do
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
end
