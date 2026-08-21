defmodule DeployEx.K6RunnerTest do
  use ExUnit.Case, async: true

  alias DeployEx.K6Runner

  describe "to_json/1" do
    test "serializes a K6Runner struct to JSON" do
      runner = %K6Runner{
        instance_id: "i-0abc123def456",
        public_ip: "54.123.45.67",
        ipv6_address: "2600:1f18::1",
        private_ip: "10.0.1.100",
        instance_name: "K6-Runner-dev-1234567890",
        state: "running",
        created_at: "2024-01-15T10:30:00Z"
      }

      json = K6Runner.to_json(runner)
      decoded = Jason.decode!(json)

      assert decoded["version"] === 1
      assert decoded["instance_id"] === "i-0abc123def456"
      assert decoded["public_ip"] === "54.123.45.67"
      assert decoded["ipv6_address"] === "2600:1f18::1"
      assert decoded["private_ip"] === "10.0.1.100"
      assert decoded["instance_name"] === "K6-Runner-dev-1234567890"
      assert decoded["state"] === "running"
      assert decoded["created_at"] === "2024-01-15T10:30:00Z"
    end

    test "handles nil values" do
      runner = %K6Runner{
        instance_id: "i-0abc123",
        public_ip: nil,
        ipv6_address: nil,
        private_ip: nil,
        instance_name: nil,
        state: nil,
        created_at: nil
      }

      json = K6Runner.to_json(runner)
      decoded = Jason.decode!(json)

      assert decoded["instance_id"] === "i-0abc123"
      assert is_nil(decoded["public_ip"])
      assert is_nil(decoded["state"])
    end
  end

  describe "from_json/1" do
    test "deserializes JSON string to K6Runner struct" do
      json = ~s({
        "version": 1,
        "instance_id": "i-0abc123def456",
        "public_ip": "54.123.45.67",
        "ipv6_address": "2600:1f18::1",
        "private_ip": "10.0.1.100",
        "instance_name": "K6-Runner-dev-1234567890",
        "state": "running",
        "created_at": "2024-01-15T10:30:00Z"
      })

      runner = K6Runner.from_json(json)

      assert runner.instance_id === "i-0abc123def456"
      assert runner.public_ip === "54.123.45.67"
      assert runner.ipv6_address === "2600:1f18::1"
      assert runner.private_ip === "10.0.1.100"
      assert runner.instance_name === "K6-Runner-dev-1234567890"
      assert runner.state === "running"
      assert runner.created_at === "2024-01-15T10:30:00Z"
    end

    test "deserializes map to K6Runner struct" do
      map = %{
        "instance_id" => "i-0abc123",
        "state" => "pending"
      }

      runner = K6Runner.from_json(map)

      assert runner.instance_id === "i-0abc123"
      assert runner.state === "pending"
      assert is_nil(runner.public_ip)
    end

    test "handles missing optional fields" do
      json = ~s({"instance_id": "i-0abc123"})

      runner = K6Runner.from_json(json)

      assert runner.instance_id === "i-0abc123"
      assert is_nil(runner.public_ip)
      assert is_nil(runner.state)
    end
  end

  describe "round-trip serialization" do
    test "to_json and from_json are inverse operations" do
      original = %K6Runner{
        instance_id: "i-0abc123def456",
        public_ip: "54.123.45.67",
        ipv6_address: "2600:1f18::1",
        private_ip: "10.0.1.100",
        instance_name: "K6-Runner-dev-1234567890",
        state: "running",
        created_at: "2024-01-15T10:30:00Z"
      }

      round_tripped = original
      |> K6Runner.to_json()
      |> K6Runner.from_json()

      assert round_tripped.instance_id === original.instance_id
      assert round_tripped.public_ip === original.public_ip
      assert round_tripped.ipv6_address === original.ipv6_address
      assert round_tripped.private_ip === original.private_ip
      assert round_tripped.instance_name === original.instance_name
      assert round_tripped.state === original.state
      assert round_tripped.created_at === original.created_at
    end

    test "round-trip with minimal data" do
      original = %K6Runner{instance_id: "i-minimal"}

      round_tripped = original
      |> K6Runner.to_json()
      |> K6Runner.from_json()

      assert round_tripped.instance_id === original.instance_id
      assert is_nil(round_tripped.public_ip)
    end
  end

  describe "state_key/1" do
    test "builds correct S3 key path" do
      assert K6Runner.state_key("i-0abc123") === "k6-runners/i-0abc123.json"
    end
  end

  describe "verify_instance_exists/1" do
    test "returns {:ok, nil} for nil input" do
      assert K6Runner.verify_instance_exists(nil) === {:ok, nil}
    end
  end

  # Behavioural pagination tests. Responses are queued in the process dictionary — per-PID
  # isolated, no setup/teardown. Mirrors test/deploy_ex/cloud/pagination_test.exs: replacing the
  # recursion with a single request makes these red.
  describe "find_runners_from_ec2/1 pagination" do
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

    defp ec2_runner_page(instance_ids, next_token) do
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

    test "concatenates every page rather than returning the first" do
      queue_responses([ec2_runner_page(["i-1", "i-2"], "TOKEN"), ec2_runner_page(["i-3"], nil)])

      assert {:ok, runners} = K6Runner.find_runners_from_ec2(request_fn: recording_request_fn())
      assert Enum.map(runners, & &1.instance_id) === ["i-1", "i-2", "i-3"]
    end

    test "terminates when no nextToken comes back" do
      queue_responses([ec2_runner_page(["i-1"], nil)])

      assert {:ok, [_only]} = K6Runner.find_runners_from_ec2(request_fn: recording_request_fn())
      assert call_count() === 1
    end
  end

  describe "fetch_all_runners/1 pagination" do
    defp s3_state_page(keys, truncated, next_marker) do
      {:ok,
       %{
         body: %{
           contents: Enum.map(keys, &%{key: &1}),
           is_truncated: truncated,
           next_marker: next_marker
         }
       }}
    end

    defp s3_get_object(runner) do
      {:ok, %{body: K6Runner.to_json(runner)}}
    end

    test "concatenates runner states across S3 pages rather than returning the first" do
      runner_one = %K6Runner{instance_id: "i-1"}
      runner_two = %K6Runner{instance_id: "i-2"}

      queue_responses([
        s3_state_page(["k6-runners/i-1.json"], "true", "k6-runners/i-1.json"),
        s3_state_page(["k6-runners/i-2.json"], "false", ""),
        s3_get_object(runner_one),
        s3_get_object(runner_two)
      ])

      assert {:ok, runners} = K6Runner.fetch_all_runners(request_fn: recording_request_fn())
      assert Enum.map(runners, & &1.instance_id) === ["i-1", "i-2"]
    end

    test "terminates when is_truncated is the STRING \"false\", which is truthy in Elixir" do
      runner = %K6Runner{instance_id: "i-only"}

      queue_responses([
        s3_state_page(["k6-runners/i-only.json"], "false", ""),
        s3_get_object(runner)
      ])

      assert {:ok, [_only]} = K6Runner.fetch_all_runners(request_fn: recording_request_fn())
      assert call_count() === 2, "a truthy string must not drive a second list request"
    end
  end
end
