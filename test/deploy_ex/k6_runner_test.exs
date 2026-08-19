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
end
