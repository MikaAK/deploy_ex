defmodule DeployEx.AwsAutoscaling do
  @moduledoc """
  AWS Auto Scaling operations using ExAws.
  """

  def describe_auto_scaling_group(asg_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    %ExAws.Operation.Query{
      path: "/",
      params: %{
        "Action" => "DescribeAutoScalingGroups",
        "AutoScalingGroupNames.member.1" => asg_name,
        "Version" => "2011-01-01"
      },
      service: :autoscaling
    }
    |> ExAws.request(region: region)
    |> handle_describe_asg_response()
  end

  def update_auto_scaling_group(asg_name, params, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    request_params = %{
      "Action" => "UpdateAutoScalingGroup",
      "AutoScalingGroupName" => asg_name,
      "Version" => "2011-01-01"
    }
    |> maybe_add_param("MinSize", params[:min_size])
    |> maybe_add_param("MaxSize", params[:max_size])
    |> maybe_add_param("DesiredCapacity", params[:desired_capacity])

    %ExAws.Operation.Query{
      path: "/",
      params: request_params,
      service: :autoscaling
    }
    |> ExAws.request(region: region)
    |> handle_update_asg_response()
  end

  def set_desired_capacity(asg_name, desired_capacity, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    %ExAws.Operation.Query{
      path: "/",
      params: %{
        "Action" => "SetDesiredCapacity",
        "AutoScalingGroupName" => asg_name,
        "DesiredCapacity" => desired_capacity,
        "Version" => "2011-01-01"
      },
      service: :autoscaling
    }
    |> ExAws.request(region: region)
    |> handle_set_capacity_response()
  end

  @valid_strategies ["Rolling", "ReplaceRootVolume"]

  def start_instance_refresh(asg_name, preferences \\ %{}, opts \\ []) do
    strategy = opts[:strategy] || "Rolling"

    if strategy not in @valid_strategies do
      {:error, ErrorMessage.bad_request(
        "invalid strategy '#{strategy}', must be one of: #{Enum.join(@valid_strategies, ", ")}"
      )}
    else
      region = opts[:region] || DeployEx.Config.aws_region()

      params = %{
        "Action" => "StartInstanceRefresh",
        "AutoScalingGroupName" => asg_name,
        "Strategy" => strategy,
        "Version" => "2011-01-01"
      }
      |> add_preferences(preferences)

      %ExAws.Operation.Query{
        path: "/",
        params: params,
        service: :autoscaling
      }
      |> ExAws.request(region: region)
      |> handle_start_refresh_response()
    end
  end

  def describe_instance_refreshes(asg_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    refresh_ids = opts[:refresh_ids] || []

    params = %{
      "Action" => "DescribeInstanceRefreshes",
      "AutoScalingGroupName" => asg_name,
      "Version" => "2011-01-01"
    }
    |> add_refresh_ids(refresh_ids)

    %ExAws.Operation.Query{
      path: "/",
      params: params,
      service: :autoscaling
    }
    |> ExAws.request(region: region)
    |> handle_describe_refreshes_response()
  end

  def describe_scaling_policies(asg_name, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    %ExAws.Operation.Query{
      path: "/",
      params: %{
        "Action" => "DescribePolicies",
        "AutoScalingGroupName" => asg_name,
        "Version" => "2011-01-01"
      },
      service: :autoscaling
    }
    |> ExAws.request(region: region)
    |> handle_describe_policies_response()
  end

  def build_asg_name(app_name, environment) do
    app_name
    |> String.replace("_", "-")
    |> Kernel.<>("-asg-#{environment}")
  end

  def build_asg_name(app_name, environment, template_key) do
    app_name
    |> String.replace("_", "-")
    |> Kernel.<>("-asg-#{template_key}-#{environment}")
  end

  def find_asg_by_prefix(app_name, environment, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()
    prefix = app_name |> String.replace("_", "-") |> Kernel.<>("-asg-")

    fetch_all_asgs(region, prefix, environment)
  end

  defp fetch_all_asgs(region, prefix, environment, next_token \\ nil, acc \\ []) do
    params = %{
      "Action" => "DescribeAutoScalingGroups",
      "Version" => "2011-01-01"
    }
    |> maybe_add_param("NextToken", next_token)

    %ExAws.Operation.Query{
      path: "/",
      params: params,
      service: :autoscaling
    }
    |> ExAws.request(region: region)
    |> case do
      {:ok, %{body: body}} ->
        case parse_xml(body) do
          %{"DescribeAutoScalingGroupsResponse" => %{"DescribeAutoScalingGroupsResult" => result}} ->
            groups = result["AutoScalingGroups"]

            matching = groups
            |> extract_list("member")
            |> Enum.filter(fn asg ->
              name = asg["AutoScalingGroupName"] || ""
              String.starts_with?(name, prefix) and String.ends_with?(name, "-#{environment}")
            end)
            |> Enum.map(&parse_asg/1)

            all_matching = acc ++ matching

            if is_nil(result["NextToken"]) do
              {:ok, all_matching}
            else
              fetch_all_asgs(region, prefix, environment, result["NextToken"], all_matching)
            end

          _ ->
            {:ok, acc}
        end

      {:error, error} ->
        {:error, ErrorMessage.failed_dependency("AWS request failed", %{error: inspect(error)})}
    end
  end

  defp add_preferences(params, preferences) do
    params
    |> maybe_add_param("Preferences.MinHealthyPercentage", preferences[:min_healthy_percentage])
    |> maybe_add_param("Preferences.MaxHealthyPercentage", preferences[:max_healthy_percentage])
    |> maybe_add_param("Preferences.InstanceWarmup", preferences[:instance_warmup])
    |> maybe_add_param("Preferences.SkipMatching", preferences[:skip_matching])
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Map.put(params, key, value)

  defp add_refresh_ids(params, []), do: params
  defp add_refresh_ids(params, refresh_ids) do
    refresh_ids
    |> Enum.with_index(1)
    |> Enum.reduce(params, fn {id, idx}, acc ->
      Map.put(acc, "InstanceRefreshIds.member.#{idx}", id)
    end)
  end

  defp handle_describe_asg_response({:ok, %{body: body}}) do
    case parse_xml(body) do
      %{"DescribeAutoScalingGroupsResponse" => %{"DescribeAutoScalingGroupsResult" => %{"AutoScalingGroups" => groups}}} ->
        case extract_list(groups, "member") do
          [asg | _] -> {:ok, parse_asg(asg)}
          [] -> {:error, ErrorMessage.not_found("autoscaling group not found")}
        end

      _ ->
        {:error, ErrorMessage.internal_server_error("failed to parse response")}
    end
  end

  defp handle_describe_asg_response({:error, {:http_error, status, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["AWS error", %{body: body}])}
  end

  defp handle_describe_asg_response({:error, error}) do
    {:error, ErrorMessage.failed_dependency("AWS request failed", %{error: inspect(error)})}
  end

  defp handle_update_asg_response({:ok, _}), do: :ok

  defp handle_update_asg_response({:error, {:http_error, status, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["AWS error", %{body: body}])}
  end

  defp handle_update_asg_response({:error, error}) do
    {:error, ErrorMessage.failed_dependency("AWS request failed", %{error: inspect(error)})}
  end

  defp handle_set_capacity_response({:ok, _}), do: :ok

  defp handle_set_capacity_response({:error, {:http_error, 400, %{body: body}}}) do
    cond do
      String.contains?(body, "ValidationError") and String.contains?(body, "outside") ->
        {:error, ErrorMessage.bad_request("desired capacity outside min/max range")}

      String.contains?(body, "does not exist") ->
        {:error, ErrorMessage.not_found("autoscaling group not found")}

      true ->
        {:error, ErrorMessage.bad_request("AWS error", %{body: body})}
    end
  end

  defp handle_set_capacity_response({:error, {:http_error, status, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["AWS error", %{body: body}])}
  end

  defp handle_set_capacity_response({:error, error}) do
    {:error, ErrorMessage.failed_dependency("AWS request failed", %{error: inspect(error)})}
  end

  defp handle_start_refresh_response({:ok, %{body: body}}) do
    case parse_xml(body) do
      %{"StartInstanceRefreshResponse" => %{"StartInstanceRefreshResult" => %{"InstanceRefreshId" => refresh_id}}} ->
        {:ok, refresh_id}

      _ ->
        {:error, ErrorMessage.internal_server_error("failed to parse response")}
    end
  end

  defp handle_start_refresh_response({:error, {:http_error, 400, %{body: body}}}) do
    cond do
      String.contains?(body, "InstanceRefreshInProgress") ->
        {:error, ErrorMessage.conflict("instance refresh already in progress")}

      String.contains?(body, "does not exist") ->
        {:error, ErrorMessage.not_found("autoscaling group not found")}

      true ->
        {:error, ErrorMessage.bad_request("AWS error", %{body: body})}
    end
  end

  defp handle_start_refresh_response({:error, {:http_error, status, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["AWS error", %{body: body}])}
  end

  defp handle_start_refresh_response({:error, error}) do
    {:error, ErrorMessage.failed_dependency("AWS request failed", %{error: inspect(error)})}
  end

  defp handle_describe_refreshes_response({:ok, %{body: body}}) do
    case parse_xml(body) do
      %{"DescribeInstanceRefreshesResponse" => %{"DescribeInstanceRefreshesResult" => %{"InstanceRefreshes" => refreshes}}} ->
        {:ok, extract_list(refreshes, "member") |> Enum.map(&parse_refresh/1)}

      _ ->
        {:error, ErrorMessage.internal_server_error("failed to parse response")}
    end
  end

  defp handle_describe_refreshes_response({:error, {:http_error, 400, %{body: body}}}) do
    if String.contains?(body, "not found") do
      {:error, ErrorMessage.not_found("autoscaling group not found")}
    else
      {:error, ErrorMessage.bad_request("AWS error", %{body: body})}
    end
  end

  defp handle_describe_refreshes_response({:error, {:http_error, status, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["AWS error", %{body: body}])}
  end

  defp handle_describe_refreshes_response({:error, error}) do
    {:error, ErrorMessage.failed_dependency("AWS request failed", %{error: inspect(error)})}
  end

  defp handle_describe_policies_response({:ok, %{body: body}}) do
    case parse_xml(body) do
      %{"DescribePoliciesResponse" => %{"DescribePoliciesResult" => %{"ScalingPolicies" => policies}}} ->
        {:ok, extract_list(policies, "member") |> Enum.map(&parse_policy/1)}

      _ ->
        {:ok, []}
    end
  end

  defp handle_describe_policies_response({:error, {:http_error, status, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["AWS error", %{body: body}])}
  end

  defp handle_describe_policies_response({:error, error}) do
    {:error, ErrorMessage.failed_dependency("AWS request failed", %{error: inspect(error)})}
  end

  defp parse_xml(body) do
    body
    |> XmlToMap.naive_map()
  rescue
    _ -> %{}
  end

  defp extract_list(nil, _key), do: []
  defp extract_list(%{} = map, _key) when map_size(map) === 0, do: []
  defp extract_list(%{} = map, key), do: List.wrap(map[key])
  defp extract_list(list, _key) when is_list(list), do: list

  defp parse_asg(asg) do
    %{
      name: asg["AutoScalingGroupName"],
      desired_capacity: parse_int(asg["DesiredCapacity"]),
      min_size: parse_int(asg["MinSize"]),
      max_size: parse_int(asg["MaxSize"]),
      instances: extract_list(asg["Instances"], "member") |> Enum.map(&parse_instance/1)
    }
  end

  defp parse_instance(instance) do
    %{
      instance_id: instance["InstanceId"],
      lifecycle_state: instance["LifecycleState"],
      health_status: instance["HealthStatus"],
      availability_zone: instance["AvailabilityZone"],
      instance_type: instance["InstanceType"],
      launch_template_version: get_in(instance, ["LaunchTemplate", "Version"])
    }
  end

  defp parse_refresh(refresh) do
    %{
      refresh_id: refresh["InstanceRefreshId"],
      status: refresh["Status"],
      status_reason: refresh["StatusReason"],
      percentage_complete: parse_int(refresh["PercentageComplete"]),
      instances_to_update: parse_int(refresh["InstancesToUpdate"]),
      start_time: refresh["StartTime"],
      end_time: refresh["EndTime"]
    }
  end

  defp parse_policy(policy) do
    %{
      policy_name: policy["PolicyName"],
      policy_type: policy["PolicyType"],
      target_tracking_configuration: parse_target_tracking(policy["TargetTrackingConfiguration"])
    }
  end

  defp parse_target_tracking(nil), do: nil
  defp parse_target_tracking(config) do
    %{
      target_value: parse_float(config["TargetValue"]),
      predefined_metric_type: get_in(config, ["PredefinedMetricSpecification", "PredefinedMetricType"])
    }
  end

  defp parse_int(nil), do: nil
  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_binary(val), do: String.to_integer(val)

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_float(val), do: val
  defp parse_float(val) when is_binary(val), do: String.to_float(val)
end
