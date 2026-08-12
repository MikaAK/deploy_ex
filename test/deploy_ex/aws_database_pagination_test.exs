defmodule DeployEx.AwsDatabasePaginationTest do
  @moduledoc """
  Behavioural test for AwsDatabase.fetch_aws_databases/1 pagination.

  DescribeDBInstances caps a response and signals more via `Marker`. A single request returns
  `{:ok, partial}` silently, never an error — this test replaces the recursion with a single
  request to prove the loop actually threads `:request_fn` through and consumes every page.

  Responses are queued in the process dictionary — per-PID isolated, no setup or teardown.
  """

  use ExUnit.Case, async: true

  alias DeployEx.AwsDatabase

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

  defp rds_page(identifiers, marker) do
    instances =
      Enum.map_join(identifiers, "", fn identifier ->
        "<DBInstance>" <>
          "<DBInstanceIdentifier>#{identifier}</DBInstanceIdentifier>" <>
          "<Endpoint><Address>#{identifier}.example.com</Address><Port>5432</Port></Endpoint>" <>
          "<MasterUsername>postgres</MasterUsername>" <>
          "<DBName>#{identifier}db</DBName>" <>
          "<TagList></TagList>" <>
          "</DBInstance>"
      end)

    marker_xml = if marker, do: "<Marker>#{marker}</Marker>", else: ""

    {:ok,
     %{
       body:
         "<DescribeDBInstancesResponse><DescribeDBInstancesResult>" <>
           "<DBInstances>#{instances}</DBInstances>#{marker_xml}" <>
           "</DescribeDBInstancesResult></DescribeDBInstancesResponse>"
     }}
  end

  describe "fetch_aws_databases/1 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([rds_page(["db-1", "db-2"], "db-2"), rds_page(["db-3"], nil)])

      assert {:ok, instances} = AwsDatabase.fetch_aws_databases(request_fn: recording_request_fn())

      assert Enum.map(instances, & &1.identifier) === ["db-1", "db-2", "db-3"]
    end

    test "terminates when the response omits Marker" do
      queue_responses([rds_page(["only"], nil)])

      assert {:ok, [_only]} = AwsDatabase.fetch_aws_databases(request_fn: recording_request_fn())
      assert call_count() === 1, "an absent Marker must not drive a second request"
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([rds_page(["db-1"], "db-1"), {:error, {"InternalError", "boom"}}])

      assert {:error, %ErrorMessage{}} =
               AwsDatabase.fetch_aws_databases(request_fn: recording_request_fn())
    end
  end
end
