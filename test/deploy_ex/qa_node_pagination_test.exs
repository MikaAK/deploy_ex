defmodule DeployEx.QaNodePaginationTest do
  @moduledoc """
  Behavioural tests for QaNode's EC2/S3 paginated lookups.

  Both DescribeInstances and ListObjects cap a single response and signal more via a
  token/marker. A single request returns `{:ok, partial}` silently, never an error — these
  tests replace the recursion (in the delegated paginators) with a single request to prove
  each site here actually threads `:request_fn` through and consumes every page.

  Responses are queued in the process dictionary — per-PID isolated, no setup or teardown.
  """

  use ExUnit.Case, async: true

  alias DeployEx.QaNode

  defp queue_responses(responses), do: Process.put(:responses, responses)

  defp next_response do
    [head | rest] = Process.get(:responses)
    Process.put(:responses, rest)
    head
  end

  defp recording_request_fn do
    fn _request, _config -> next_response() end
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
          "<tagSet><item><key>InstanceGroup</key><value>my_app_qa</value></item></tagSet>" <>
          "</item></instancesSet></item>"
      end)

    token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

    {:ok,
     %{
       body:
         "<DescribeInstancesResponse><reservationSet>#{items}</reservationSet>#{token}</DescribeInstancesResponse>"
     }}
  end

  defp get_object_page(json) do
    {:ok, %{body: json}}
  end

  describe "find_qa_nodes_by_branch/2 pagination" do
    test "concatenates every EC2 page rather than returning the first" do
      queue_responses([ec2_page(["i-1", "i-2"], "TOKEN"), ec2_page(["i-3"], nil)])

      assert {:ok, nodes} =
               QaNode.find_qa_nodes_by_branch("main", request_fn: recording_request_fn())

      assert Enum.map(nodes, & &1.instance_id) === ["i-1", "i-2", "i-3"]
    end
  end

  describe "find_qa_nodes_from_ec2/2 pagination" do
    test "concatenates every EC2 page rather than returning the first" do
      queue_responses([ec2_page(["i-1"], "TOKEN"), ec2_page(["i-2"], nil)])

      assert {:ok, nodes} =
               QaNode.find_qa_nodes_from_ec2("my_app", request_fn: recording_request_fn())

      assert Enum.map(nodes, & &1.instance_id) === ["i-1", "i-2"]
    end
  end

  describe "find_qa_node_from_ec2/2 pagination" do
    test "still returns the first match once every page has been consumed" do
      queue_responses([ec2_page(["i-1"], "TOKEN"), ec2_page(["i-2"], nil)])

      assert {:ok, node} =
               QaNode.find_qa_node_from_ec2("my_app", request_fn: recording_request_fn())

      assert node.instance_id === "i-1"
    end

    test "returns nil, not an error, when no page has a match" do
      queue_responses([ec2_page([], nil)])

      assert {:ok, nil} =
               QaNode.find_qa_node_from_ec2("my_app", request_fn: recording_request_fn())
    end
  end

  describe "list_all_qa_states/1 pagination" do
    test "concatenates every S3 page into a deduped app_name list" do
      queue_responses([
        s3_page(["qa-nodes/app_a/i-1.json", "qa-nodes/app_b/i-2.json"], "true", "qa-nodes/app_b/i-2.json"),
        s3_page(["qa-nodes/app_a/i-3.json"], "false", "")
      ])

      assert {:ok, app_names} = QaNode.list_all_qa_states(request_fn: recording_request_fn())

      assert Enum.sort(app_names) === ["app_a", "app_b"]
    end
  end

  describe "fetch_all_qa_states_for_app/2 pagination" do
    test "fetches every key across every S3 page, not just the first page" do
      queue_responses([
        s3_page(["qa-nodes/my_app/i-1.json", "qa-nodes/my_app/i-2.json"], "true", "qa-nodes/my_app/i-2.json"),
        s3_page(["qa-nodes/my_app/i-3.json"], "false", ""),
        get_object_page(~s({"instance_id":"i-1","app_name":"my_app"})),
        get_object_page(~s({"instance_id":"i-2","app_name":"my_app"})),
        get_object_page(~s({"instance_id":"i-3","app_name":"my_app"}))
      ])

      assert {:ok, states} =
               QaNode.fetch_all_qa_states_for_app("my_app", request_fn: recording_request_fn())

      assert Enum.map(states, & &1.instance_id) === ["i-1", "i-2", "i-3"]
    end
  end
end
