defmodule Mix.Tasks.Terraform.EbsSnapshotPaginationTest do
  @moduledoc """
  Behavioural tests for the EC2 DescribeVolumes/DescribeSnapshots paginators added to
  terraform.delete_ebs_snapshot.ex and terraform.create_ebs_snapshot.ex.

  Same pattern as test/deploy_ex/cloud/pagination_test.exs: replacing the recursion with a
  single request makes these red. Responses are queued in the process dictionary -- per-PID
  isolated, no setup or teardown, and no mocking library involved.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Terraform.CreateEbsSnapshot
  alias Mix.Tasks.Terraform.DeleteEbsSnapshot

  defp queue_responses(responses), do: Process.put(:responses, responses)

  defp next_response do
    [head | rest] = Process.get(:responses)
    Process.put(:responses, rest)
    Process.put(:call_count, (Process.get(:call_count) || 0) + 1)

    head
  end

  defp call_count, do: Process.get(:call_count) || 0

  defp recording_request_fn do
    fn request, _config ->
      next_token = request |> Map.get(:params, %{}) |> Map.get("NextToken")
      Process.put(:next_tokens, (Process.get(:next_tokens) || []) ++ [next_token])

      next_response()
    end
  end

  defp volumes_page(volume_ids, next_token) do
    items =
      Enum.map_join(volume_ids, "", fn id ->
        "<item><volumeId>#{id}</volumeId><size>100</size></item>"
      end)

    token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

    {:ok, %{body: "<DescribeVolumesResponse><volumeSet>#{items}</volumeSet>#{token}</DescribeVolumesResponse>"}}
  end

  defp snapshots_page(snapshot_ids, next_token) do
    items =
      Enum.map_join(snapshot_ids, "", fn id ->
        "<item><snapshotId>#{id}</snapshotId><volumeId>vol-1</volumeId>" <>
          "<description>d</description><startTime>2024-01-01T00:00:00.000Z</startTime></item>"
      end)

    token = if next_token, do: "<nextToken>#{next_token}</nextToken>", else: ""

    {:ok,
     %{body: "<DescribeSnapshotsResponse><snapshotSet>#{items}</snapshotSet>#{token}</DescribeSnapshotsResponse>"}}
  end

  defp instance(instance_id), do: %{"instanceId" => instance_id}
  defp volume(volume_id), do: %{"volumeId" => volume_id}

  describe "DeleteEbsSnapshot.find_volumes_for_instances/3 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([volumes_page(["vol-1", "vol-2"], "TOKEN"), volumes_page(["vol-3"], nil)])

      assert {:ok, volumes} =
               DeleteEbsSnapshot.find_volumes_for_instances(
                 "us-east-1",
                 [instance("i-1")],
                 request_fn: recording_request_fn()
               )

      assert Enum.map(volumes, & &1["volumeId"]) === ["vol-1", "vol-2", "vol-3"]
    end

    test "terminates when no nextToken comes back" do
      queue_responses([volumes_page(["vol-1"], nil)])

      assert {:ok, [_only]} =
               DeleteEbsSnapshot.find_volumes_for_instances(
                 "us-east-1",
                 [instance("i-1")],
                 request_fn: recording_request_fn()
               )

      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([volumes_page(["vol-1"], "TOKEN"), {:error, {:http_error, 500, %{body: "boom"}}}])

      assert {:error, %ErrorMessage{}} =
               DeleteEbsSnapshot.find_volumes_for_instances(
                 "us-east-1",
                 [instance("i-1")],
                 request_fn: recording_request_fn()
               )
    end
  end

  describe "DeleteEbsSnapshot.find_snapshots_for_volumes/3 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([snapshots_page(["snap-1", "snap-2"], "TOKEN"), snapshots_page(["snap-3"], nil)])

      assert {:ok, snapshots} =
               DeleteEbsSnapshot.find_snapshots_for_volumes(
                 "us-east-1",
                 [volume("vol-1")],
                 request_fn: recording_request_fn()
               )

      assert Enum.map(snapshots, & &1.snapshot_id) === ["snap-1", "snap-2", "snap-3"]
    end

    test "terminates when no nextToken comes back" do
      queue_responses([snapshots_page(["snap-1"], nil)])

      assert {:ok, [_only]} =
               DeleteEbsSnapshot.find_snapshots_for_volumes(
                 "us-east-1",
                 [volume("vol-1")],
                 request_fn: recording_request_fn()
               )

      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([snapshots_page(["snap-1"], "TOKEN"), {:error, {:http_error, 500, %{body: "boom"}}}])

      assert {:error, %ErrorMessage{}} =
               DeleteEbsSnapshot.find_snapshots_for_volumes(
                 "us-east-1",
                 [volume("vol-1")],
                 request_fn: recording_request_fn()
               )
    end
  end

  describe "DeleteEbsSnapshot.get_snapshots_by_ids/3 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([snapshots_page(["snap-1"], "TOKEN"), snapshots_page(["snap-2"], nil)])

      assert {:ok, snapshots} =
               DeleteEbsSnapshot.get_snapshots_by_ids(
                 "us-east-1",
                 ["snap-1", "snap-2"],
                 request_fn: recording_request_fn()
               )

      assert Enum.map(snapshots, & &1.snapshot_id) === ["snap-1", "snap-2"]
    end

    test "terminates when no nextToken comes back" do
      queue_responses([snapshots_page(["snap-1"], nil)])

      assert {:ok, [_only]} =
               DeleteEbsSnapshot.get_snapshots_by_ids(
                 "us-east-1",
                 ["snap-1"],
                 request_fn: recording_request_fn()
               )

      assert call_count() === 1
    end

    test "drops max_results instead of sending it alongside snapshot_ids" do
      # AWS rejects DescribeSnapshots when SnapshotIds and MaxResults are both present
      # ("InvalidParameterCombination") -- confirmed against a live account.
      queue_responses([snapshots_page(["snap-1"], nil)])

      request_fn = fn request, _config ->
        refute Map.has_key?(request.params, "MaxResults")
        next_response()
      end

      assert {:ok, [_only]} =
               DeleteEbsSnapshot.get_snapshots_by_ids(
                 "us-east-1",
                 ["snap-1"],
                 max_results: 5,
                 request_fn: request_fn
               )
    end
  end

  describe "CreateEbsSnapshot.find_volumes_for_instances/3 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([volumes_page(["vol-1", "vol-2"], "TOKEN"), volumes_page(["vol-3"], nil)])

      assert {:ok, volumes} =
               CreateEbsSnapshot.find_volumes_for_instances(
                 "us-east-1",
                 [instance("i-1")],
                 request_fn: recording_request_fn()
               )

      assert Enum.map(volumes, & &1["volumeId"]) === ["vol-1", "vol-2", "vol-3"]
    end

    test "terminates when no nextToken comes back" do
      queue_responses([volumes_page(["vol-1"], nil)])

      assert {:ok, [_only]} =
               CreateEbsSnapshot.find_volumes_for_instances(
                 "us-east-1",
                 [instance("i-1")],
                 request_fn: recording_request_fn()
               )

      assert call_count() === 1
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([volumes_page(["vol-1"], "TOKEN"), {:error, {:http_error, 500, %{body: "boom"}}}])

      assert {:error, %ErrorMessage{}} =
               CreateEbsSnapshot.find_volumes_for_instances(
                 "us-east-1",
                 [instance("i-1")],
                 request_fn: recording_request_fn()
               )
    end
  end
end
