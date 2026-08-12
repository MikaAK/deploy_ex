defmodule DeployEx.AwsDynamodbPaginationTest do
  @moduledoc """
  Behavioural test for AwsDynamodb.list_tables/2 pagination.

  ListTables caps a response and signals more via `LastEvaluatedTableName`. A single request
  returns `{:ok, partial}` silently, never an error — this test replaces the recursion with a
  single request to prove the loop actually threads `:request_fn` through and consumes every
  page. Live account has zero tables today, so this is the only way to exercise the loop.

  Responses are queued in the process dictionary — per-PID isolated, no setup or teardown.
  """

  use ExUnit.Case, async: true

  alias DeployEx.AwsDynamodb

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

  defp dynamo_page(table_names, last_evaluated) do
    body =
      if last_evaluated,
        do: %{"TableNames" => table_names, "LastEvaluatedTableName" => last_evaluated},
        else: %{"TableNames" => table_names}

    {:ok, body}
  end

  describe "list_tables/2 pagination" do
    test "concatenates every page rather than returning the first" do
      queue_responses([dynamo_page(["a", "b"], "b"), dynamo_page(["c"], nil)])

      assert AwsDynamodb.list_tables("us-east-1", request_fn: recording_request_fn()) ===
               {:ok, ["a", "b", "c"]}
    end

    test "terminates when the response omits LastEvaluatedTableName" do
      queue_responses([dynamo_page(["only"], nil)])

      assert AwsDynamodb.list_tables("us-east-1", request_fn: recording_request_fn()) === {:ok, ["only"]}
      assert call_count() === 1, "an absent LastEvaluatedTableName must not drive a second request"
    end

    test "an error on a later page fails loudly instead of returning a partial list" do
      queue_responses([dynamo_page(["a"], "a"), {:error, {:http_error, 500, "boom"}}])

      assert {:error, %ErrorMessage{}} =
               AwsDynamodb.list_tables("us-east-1", request_fn: recording_request_fn())
    end
  end
end
