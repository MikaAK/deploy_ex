defmodule DeployEx.AwsLoadBalancerTest do
  @moduledoc """
  Behavioural tests for `describe_target_groups/1` pagination.

  DescribeTargetGroups caps a response and signals more via NextMarker. A single request
  returns `{:ok, partial}` silently, never an error — this test replaces the recursion with a
  single request to prove it actually threads `:request_fn` through and consumes every page.
  """

  use ExUnit.Case, async: true

  alias DeployEx.AwsLoadBalancer

  defp queue_responses(responses), do: Process.put(:responses, responses)

  defp next_response do
    [head | rest] = Process.get(:responses)
    Process.put(:responses, rest)
    Process.put(:call_count, (Process.get(:call_count) || 0) + 1)
    head
  end

  defp call_count, do: Process.get(:call_count) || 0

  defp recording_request_fn do
    fn _request, _config -> next_response() end
  end

  defp tg_page(names, next_marker) do
    target_groups =
      Enum.map(names, fn name ->
        %{
          target_group_arn: "arn:aws:elasticloadbalancing:us-east-1:1:targetgroup/#{name}",
          target_group_name: name,
          port: 4000,
          protocol: "HTTP",
          vpc_id: "vpc-1",
          health_check_path: "/health",
          health_check_port: "4000",
          health_check_protocol: "HTTP"
        }
      end)

    {:ok, %{body: %{target_groups: target_groups, next_marker: next_marker}}}
  end

  describe "describe_target_groups/1 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([tg_page(["a"], "TOKEN"), tg_page(["b"], "")])

      assert {:ok, target_groups} = AwsLoadBalancer.describe_target_groups(request_fn: recording_request_fn())

      assert Enum.map(target_groups, & &1.name) === ["a", "b"]
    end

    test "terminates when next_marker is the empty string" do
      queue_responses([tg_page(["only"], "")])

      assert {:ok, [_only]} = AwsLoadBalancer.describe_target_groups(request_fn: recording_request_fn())
      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([tg_page(["a"], "TOKEN"), {:error, {:http_error, 500, %{body: "boom"}}}])

      assert {:error, %ErrorMessage{}} =
               AwsLoadBalancer.describe_target_groups(request_fn: recording_request_fn())
    end
  end

  describe "find_target_groups_by_app/2 pagination" do
    test "a matching target group past page one is still found, not silently dropped" do
      queue_responses([tg_page(["other-app"], "TOKEN"), tg_page(["my_app"], "")])

      assert {:ok, [%{name: "my_app"}]} =
               AwsLoadBalancer.find_target_groups_by_app("my_app", request_fn: recording_request_fn())
    end
  end
end
