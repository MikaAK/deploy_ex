defmodule DeployEx.AwsLoadBalancer do
  @moduledoc """
  AWS Elastic Load Balancer operations for managing target group registrations.
  """

  # ex_aws_elastic_load_balancing wraps its V2 parser in
  # `if Code.ensure_loaded?(SweetXml) do` at compile time. If sweet_xml hasn't
  # compiled when the dep compiled, the parser .beam never exists and ExAws
  # silently returns raw XML bodies. Fail loudly at compile time so the broken
  # build is caught instead of producing fragile runtime XML fallbacks.
  unless Code.ensure_loaded?(ExAws.ElasticLoadBalancingV2.Parsers) do
    raise CompileError,
      description:
        "ExAws.ElasticLoadBalancingV2.Parsers missing — sweet_xml must compile before " <>
          "ex_aws_elastic_load_balancing. Run: " <>
          "mix deps.clean ex_aws_elastic_load_balancing ex_aws_s3 --build && " <>
          "mix deps.compile sweet_xml && mix deps.compile"
  end

  def register_target(target_group_arn, instance_id, port, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    target_group_arn
    |> ExAws.ElasticLoadBalancingV2.register_targets([%{id: instance_id, port: port}])
    |> ExAws.request(region: region)
    |> handle_register_response()
  end

  def deregister_target(target_group_arn, instance_id, port, opts) do
    region = opts[:region] || DeployEx.Config.aws_region()

    target_group_arn
    |> ExAws.ElasticLoadBalancingV2.deregister_targets([%{id: instance_id, port: port}])
    |> ExAws.request(region: region)
    |> handle_deregister_response()
  end

  def describe_target_health(target_group_arn, opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    target_group_arn
    |> ExAws.ElasticLoadBalancingV2.describe_target_health()
    |> ExAws.request(region: region)
    |> handle_health_response()
  end

  def describe_target_groups(opts \\ []) do
    region = opts[:region] || DeployEx.Config.aws_region()

    ExAws.ElasticLoadBalancingV2.describe_target_groups()
    |> ExAws.request(region: region)
    |> handle_target_groups_response()
  end

  def find_target_groups_by_app(app_name, opts \\ []) do
    with {:ok, target_groups} <- describe_target_groups(opts) do
      filtered = Enum.filter(target_groups, fn tg ->
        String.contains?(tg.name, app_name) or String.contains?(tg.name, String.replace(app_name, "_", "-"))
      end)

      {:ok, filtered}
    end
  end

  def wait_for_healthy(target_group_arn, instance_id, timeout \\ 300_000, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    do_wait_for_healthy(target_group_arn, instance_id, start_time, timeout, opts)
  end

  defp do_wait_for_healthy(target_group_arn, instance_id, start_time, timeout, opts) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      {:error, ErrorMessage.request_timeout("timed out waiting for target to become healthy")}
    else
      case describe_target_health(target_group_arn, opts) do
        {:ok, targets} ->
          target = Enum.find(targets, &(&1.id === instance_id))

          case target do
            %{state: "healthy"} ->
              :ok

            %{state: state} when state in ["initial", "draining"] ->
              Process.sleep(5000)
              do_wait_for_healthy(target_group_arn, instance_id, start_time, timeout, opts)

            %{state: "unhealthy", reason: reason} ->
              {:error, ErrorMessage.failed_dependency("target is unhealthy", %{reason: reason})}

            nil ->
              {:error, ErrorMessage.not_found("target not found in target group")}
          end

        error ->
          error
      end
    end
  end

  defp handle_register_response({:ok, _}), do: :ok

  defp handle_register_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error registering target",
      %{error_body: body}
    ])}
  end

  defp handle_deregister_response({:ok, _}), do: :ok

  defp handle_deregister_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error deregistering target",
      %{error_body: body}
    ])}
  end

  defp handle_health_response({:ok, %{body: %{target_health_descriptions: descriptions}}}) do
    targets = descriptions
    |> List.wrap()
    |> Enum.flat_map(fn desc ->
      Enum.map(desc[:targets] || [], fn target ->
        %{
          id: target[:id],
          port: target[:port] |> parse_integer(),
          state: desc[:target_health],
          reason: desc[:target_health_reason],
          description: desc[:target_health_description]
        }
      end)
    end)

    {:ok, targets}
  end

  defp handle_health_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error describing target health",
      %{error_body: body}
    ])}
  end

  defp handle_target_groups_response({:ok, %{body: %{target_groups: target_groups}}}) do
    parsed = Enum.map(target_groups, fn tg ->
      %{
        arn: tg[:target_group_arn],
        name: tg[:target_group_name],
        port: tg[:port] |> parse_integer(),
        protocol: tg[:protocol],
        vpc_id: tg[:vpc_id],
        health_check_path: tg[:health_check_path],
        health_check_port: tg[:health_check_port],
        health_check_protocol: tg[:health_check_protocol]
      }
    end)

    {:ok, parsed}
  end

  defp handle_target_groups_response({:error, {:http_error, status_code, %{body: body}}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status_code), [
      "error describing target groups",
      %{error_body: body}
    ])}
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(val) when is_integer(val), do: val
  defp parse_integer(val) when is_binary(val), do: String.to_integer(val)
end
