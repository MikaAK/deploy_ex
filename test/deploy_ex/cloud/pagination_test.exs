defmodule DeployEx.Cloud.PaginationTest do
  @moduledoc """
  Behavioural tests for the two paginators.

  Both fixes originally shipped with source-grep pins, which cannot fail when the loop is deleted.
  Every test here does: replacing the recursion with a single request makes it red.

  Responses are queued in the process dictionary — per-PID isolated, no setup or teardown, and no
  cache involved.
  """

  use ExUnit.Case, async: true

  alias DeployEx.Cloud.S3ObjectStore

  defp queue_responses(responses), do: Process.put(:responses, responses)

  defp next_response do
    [head | rest] = Process.get(:responses)
    Process.put(:responses, rest)
    Process.put(:call_count, (Process.get(:call_count) || 0) + 1)

    head
  end

  defp call_count, do: Process.get(:call_count) || 0

  # The marker rides in the request struct's params, not in the config keyword list — config
  # carries only region and credentials.
  defp recording_request_fn do
    fn request, _config ->
      marker = request |> Map.get(:params, %{}) |> Map.get("marker")
      Process.put(:markers, (Process.get(:markers) || []) ++ [marker])

      next_response()
    end
  end

  defp s3_page(keys, truncated, next_marker) do
    {:ok,
     %{
       body: %{
         contents: Enum.map(keys, &%{key: &1}),
         is_truncated: truncated,
         next_marker: next_marker
       }
     }}
  end

  defp ec2_page(instance_ids, next_token) do
    items =
      Enum.map_join(instance_ids, "", fn id ->
        "<item><instancesSet><item>" <>
          "<instanceId>#{id}</instanceId>" <>
          "<instanceState><name>running</name></instanceState>" <>
          "</item></instancesSet></item>"
      end)

    token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

    {:ok,
     %{
       body:
         "<DescribeInstancesResponse><reservationSet>#{items}</reservationSet>#{token}</DescribeInstancesResponse>"
     }}
  end

  describe "S3ObjectStore.list_objects/2 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([s3_page(["a", "b"], "true", "b"), s3_page(["c"], "false", "")])

      assert S3ObjectStore.list_objects("bucket",
               request_fn: recording_request_fn(),
               prefix: "p/"
             ) === {:ok, ["a", "b", "c"]}
    end

    test "terminates when is_truncated is the STRING \"false\", which is truthy in Elixir" do
      queue_responses([s3_page(["only"], "false", "")])

      assert S3ObjectStore.list_objects("bucket", request_fn: recording_request_fn()) ===
               {:ok, ["only"]}

      assert call_count() === 1, "a truthy string must not drive a second request"
    end

    test "advances the marker between pages instead of refetching page one" do
      queue_responses([s3_page(["a"], "true", "a"), s3_page(["b"], "false", "")])

      S3ObjectStore.list_objects("bucket", request_fn: recording_request_fn())

      assert Process.get(:markers) === [nil, "a"]
    end

    test "falls back to the last key when next_marker is empty" do
      queue_responses([s3_page(["k1", "k2"], "true", ""), s3_page([], "false", "")])

      S3ObjectStore.list_objects("bucket", request_fn: recording_request_fn())

      assert Process.get(:markers) === [nil, "k2"]
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([s3_page(["a"], "true", "a"), {:error, {:http_error, 500, %{body: "boom"}}}])

      assert {:error, %ErrorMessage{}} =
               S3ObjectStore.list_objects("bucket", request_fn: recording_request_fn())
    end
  end

  describe "AwsMachine.fetch_instances/2 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([ec2_page(["i-1", "i-2"], "TOKEN"), ec2_page(["i-3"], nil)])

      assert {:ok, instances} =
               DeployEx.AwsMachine.fetch_instances("us-east-1", request_fn: recording_request_fn())

      assert Enum.map(instances, & &1["instanceId"]) === ["i-1", "i-2", "i-3"]
    end

    test "terminates when no nextToken comes back" do
      queue_responses([ec2_page(["i-1"], nil)])

      assert {:ok, [_only]} =
               DeployEx.AwsMachine.fetch_instances("us-east-1", request_fn: recording_request_fn())

      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([ec2_page(["i-1"], "TOKEN"), {:error, {:http_error, 503, %{body: "nope"}}}])

      assert {:error, %ErrorMessage{}} =
               DeployEx.AwsMachine.fetch_instances("us-east-1", request_fn: recording_request_fn())
    end
  end
end
