defmodule DeployEx.QaNodeTest do
  use ExUnit.Case, async: true

  alias DeployEx.QaNode

  describe "to_json/1" do
    test "serializes a QaNode struct to JSON" do
      qa_node = %QaNode{
        instance_id: "i-0abc123def456",
        app_name: "my_app",
        target_sha: "abc1234567890",
        public_ip: "54.123.45.67",
        ipv6_address: "2600:1f18::1",
        private_ip: "10.0.1.100",
        instance_name: "my_app-qa-abc1234-1234567890",
        state: "running",
        created_at: "2024-01-15T10:30:00Z",
        load_balancer_attached?: true,
        target_group_arns: ["arn:aws:elasticloadbalancing:us-west-2:123456789:targetgroup/my-tg/abc123"]
      }

      json = QaNode.to_json(qa_node)
      decoded = Jason.decode!(json)

      assert decoded["version"] === 1
      assert decoded["instance_id"] === "i-0abc123def456"
      assert decoded["app_name"] === "my_app"
      assert decoded["target_sha"] === "abc1234567890"
      assert decoded["public_ip"] === "54.123.45.67"
      assert decoded["ipv6_address"] === "2600:1f18::1"
      assert decoded["private_ip"] === "10.0.1.100"
      assert decoded["instance_name"] === "my_app-qa-abc1234-1234567890"
      assert decoded["state"] === "running"
      assert decoded["created_at"] === "2024-01-15T10:30:00Z"
      assert decoded["load_balancer_attached"] === true
      assert decoded["target_group_arns"] === ["arn:aws:elasticloadbalancing:us-west-2:123456789:targetgroup/my-tg/abc123"]
    end

    test "handles nil values" do
      qa_node = %QaNode{
        instance_id: nil,
        app_name: "my_app",
        target_sha: "abc1234",
        public_ip: nil,
        ipv6_address: nil,
        private_ip: nil,
        instance_name: nil,
        state: nil,
        created_at: nil,
        load_balancer_attached?: false,
        target_group_arns: []
      }

      json = QaNode.to_json(qa_node)
      decoded = Jason.decode!(json)

      assert decoded["instance_id"] === nil
      assert decoded["public_ip"] === nil
      assert decoded["load_balancer_attached"] === false
      assert decoded["target_group_arns"] === []
    end
  end

  describe "from_json/1" do
    test "deserializes JSON string to QaNode struct" do
      json = ~s({
        "version": 1,
        "instance_id": "i-0abc123def456",
        "app_name": "my_app",
        "target_sha": "abc1234567890",
        "public_ip": "54.123.45.67",
        "ipv6_address": "2600:1f18::1",
        "private_ip": "10.0.1.100",
        "instance_name": "my_app-qa-abc1234-1234567890",
        "state": "running",
        "created_at": "2024-01-15T10:30:00Z",
        "load_balancer_attached": true,
        "target_group_arns": ["arn:aws:elasticloadbalancing:us-west-2:123456789:targetgroup/my-tg/abc123"]
      })

      qa_node = QaNode.from_json(json)

      assert qa_node.instance_id === "i-0abc123def456"
      assert qa_node.app_name === "my_app"
      assert qa_node.target_sha === "abc1234567890"
      assert qa_node.public_ip === "54.123.45.67"
      assert qa_node.ipv6_address === "2600:1f18::1"
      assert qa_node.private_ip === "10.0.1.100"
      assert qa_node.instance_name === "my_app-qa-abc1234-1234567890"
      assert qa_node.state === "running"
      assert qa_node.created_at === "2024-01-15T10:30:00Z"
      assert qa_node.load_balancer_attached? === true
      assert qa_node.target_group_arns === ["arn:aws:elasticloadbalancing:us-west-2:123456789:targetgroup/my-tg/abc123"]
    end

    test "deserializes map to QaNode struct" do
      map = %{
        "instance_id" => "i-0abc123",
        "app_name" => "test_app",
        "target_sha" => "def5678",
        "load_balancer_attached" => false,
        "target_group_arns" => []
      }

      qa_node = QaNode.from_json(map)

      assert qa_node.instance_id === "i-0abc123"
      assert qa_node.app_name === "test_app"
      assert qa_node.target_sha === "def5678"
      assert qa_node.load_balancer_attached? === false
      assert qa_node.target_group_arns === []
    end

    test "handles missing optional fields with defaults" do
      json = ~s({
        "instance_id": "i-0abc123",
        "app_name": "my_app",
        "target_sha": "abc1234"
      })

      qa_node = QaNode.from_json(json)

      assert qa_node.load_balancer_attached? === false
      assert qa_node.target_group_arns === []
      assert qa_node.public_ip === nil
    end
  end

  describe "round-trip serialization" do
    test "to_json and from_json are inverse operations" do
      original = %QaNode{
        instance_id: "i-0abc123def456",
        app_name: "my_app",
        target_sha: "abc1234567890",
        public_ip: "54.123.45.67",
        ipv6_address: "2600:1f18::1",
        private_ip: "10.0.1.100",
        instance_name: "my_app-qa-abc1234-1234567890",
        state: "running",
        created_at: "2024-01-15T10:30:00Z",
        load_balancer_attached?: true,
        target_group_arns: ["arn:aws:tg/1", "arn:aws:tg/2"]
      }

      round_tripped = original
      |> QaNode.to_json()
      |> QaNode.from_json()

      assert round_tripped.instance_id === original.instance_id
      assert round_tripped.app_name === original.app_name
      assert round_tripped.target_sha === original.target_sha
      assert round_tripped.public_ip === original.public_ip
      assert round_tripped.ipv6_address === original.ipv6_address
      assert round_tripped.private_ip === original.private_ip
      assert round_tripped.instance_name === original.instance_name
      assert round_tripped.state === original.state
      assert round_tripped.created_at === original.created_at
      assert round_tripped.load_balancer_attached? === original.load_balancer_attached?
      assert round_tripped.target_group_arns === original.target_group_arns
    end

    test "round-trip with minimal data" do
      original = %QaNode{
        app_name: "minimal_app",
        target_sha: "abc123",
        load_balancer_attached?: false,
        target_group_arns: []
      }

      round_tripped = original
      |> QaNode.to_json()
      |> QaNode.from_json()

      assert round_tripped.app_name === original.app_name
      assert round_tripped.target_sha === original.target_sha
      assert round_tripped.load_balancer_attached? === false
      assert round_tripped.target_group_arns === []
    end
  end

  describe "qa_state_key/2" do
    test "builds correct S3 key path" do
      assert QaNode.qa_state_key("my_app", "i-abc123") === "qa-nodes/my_app/i-abc123.json"
      assert QaNode.qa_state_key("another_app", "i-def456") === "qa-nodes/another_app/i-def456.json"
    end
  end

  describe "verify_instance_exists/1" do
    test "returns {:ok, nil} for nil input" do
      assert QaNode.verify_instance_exists(nil) === {:ok, nil}
    end
  end
end
