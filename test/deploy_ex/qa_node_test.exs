defmodule DeployEx.QaNodeTest do
  use ExUnit.Case, async: true

  alias DeployEx.QaNode

  describe "use_public_ip_cert? roundtrip" do
    test "to_json/from_json preserves use_public_ip_cert?: true" do
      qa_node = %QaNode{
        instance_id: "i-abc",
        app_name: "my_app",
        target_sha: "abc1234",
        use_public_ip_cert?: true
      }

      decoded = qa_node |> QaNode.to_json() |> QaNode.from_json()
      assert decoded.use_public_ip_cert? === true
    end

    test "from_json defaults use_public_ip_cert? to false when key absent (old state)" do
      legacy_json = Jason.encode!(%{
        "version" => 1,
        "instance_id" => "i-old",
        "app_name" => "my_app",
        "target_sha" => "abc1234"
      })

      decoded = QaNode.from_json(legacy_json)
      assert decoded.use_public_ip_cert? === false
    end

    test "build_qa_node_from_instance reads UsePublicIpCert tag as boolean" do
      instance = %{
        "instanceId" => "i-0xyz",
        "ipAddress" => nil,
        "privateIpAddress" => nil,
        "instanceState" => %{"name" => "running"},
        "launchTime" => "2024-01-15T10:00:00Z",
        "tagSet" => %{
          "item" => [
            %{"key" => "InstanceGroup", "value" => "my_app_prod"},
            %{"key" => "TargetSha", "value" => "abc1234"},
            %{"key" => "UsePublicIpCert", "value" => "true"}
          ]
        }
      }

      qa_node = QaNode.build_qa_node_from_instance(instance)
      assert qa_node.use_public_ip_cert? === true
    end

    test "build_qa_node_from_instance treats missing UsePublicIpCert tag as false" do
      instance = %{
        "instanceId" => "i-0xyz",
        "ipAddress" => nil,
        "privateIpAddress" => nil,
        "instanceState" => %{"name" => "running"},
        "launchTime" => "2024-01-15T10:00:00Z",
        "tagSet" => %{
          "item" => [
            %{"key" => "InstanceGroup", "value" => "my_app_prod"},
            %{"key" => "TargetSha", "value" => "abc1234"}
          ]
        }
      }

      qa_node = QaNode.build_qa_node_from_instance(instance)
      assert qa_node.use_public_ip_cert? === false
    end
  end

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

  describe "s3_state_stale?/2" do
    test "returns false when both states are identical" do
      old = %QaNode{
        instance_id: "i-abc",
        app_name: "my_app",
        target_sha: "abc1234",
        public_ip: "54.1.2.3",
        private_ip: "10.0.0.1",
        ipv6_address: nil,
        state: "running"
      }

      new = old

      refute QaNode.s3_state_stale?(old, new)
    end

    test "returns true when S3 has nil public_ip and EC2 has a value" do
      old = %QaNode{
        instance_id: "i-abc",
        app_name: "my_app",
        target_sha: "abc1234",
        public_ip: nil,
        private_ip: nil,
        ipv6_address: nil,
        state: nil
      }

      new = %{old |
        public_ip: "54.1.2.3",
        private_ip: "10.0.0.1",
        state: "running"
      }

      assert QaNode.s3_state_stale?(old, new)
    end

    test "returns true when state transitions (e.g., pending -> running)" do
      old = %QaNode{
        instance_id: "i-abc",
        app_name: "my_app",
        target_sha: "abc1234",
        public_ip: "54.1.2.3",
        state: "pending"
      }

      new = %{old | state: "running"}

      assert QaNode.s3_state_stale?(old, new)
    end

    test "returns true when only ipv6_address changes" do
      old = %QaNode{
        instance_id: "i-abc",
        app_name: "my_app",
        target_sha: "abc1234",
        public_ip: "54.1.2.3",
        ipv6_address: nil,
        state: "running"
      }

      new = %{old | ipv6_address: "2600:1f18::1"}

      assert QaNode.s3_state_stale?(old, new)
    end

    test "returns false when only fields outside the refresh set differ" do
      old = %QaNode{
        instance_id: "i-abc",
        app_name: "my_app",
        target_sha: "abc1234",
        instance_name: "old-name",
        public_ip: "54.1.2.3",
        private_ip: "10.0.0.1",
        ipv6_address: nil,
        state: "running"
      }

      new = %{old | instance_name: "new-name"}

      refute QaNode.s3_state_stale?(old, new)
    end
  end

  describe "merge_ec2_state/2" do
    test "merges EC2 ip/state fields onto the S3 state" do
      s3_state = %QaNode{
        instance_id: "i-abc",
        app_name: "my_app",
        target_sha: "abc1234",
        instance_tag: "feat",
        git_branch: "feat/x",
        instance_name: "my_app-prod-qa-abc1234-111",
        load_balancer_attached?: true,
        target_group_arns: ["arn:aws:tg/1"],
        use_public_ip_cert?: true,
        public_ip: nil,
        private_ip: nil,
        ipv6_address: nil,
        state: nil
      }

      ec2_instance = %{
        "ipAddress" => "54.1.2.3",
        "ipv6Address" => "2600:1f18::1",
        "privateIpAddress" => "10.0.0.1",
        "instanceState" => %{"name" => "running"}
      }

      merged = QaNode.merge_ec2_state(s3_state, ec2_instance)

      assert merged.public_ip === "54.1.2.3"
      assert merged.ipv6_address === "2600:1f18::1"
      assert merged.private_ip === "10.0.0.1"
      assert merged.state === "running"
      # S3-only fields preserved
      assert merged.instance_tag === "feat"
      assert merged.git_branch === "feat/x"
      assert merged.instance_name === "my_app-prod-qa-abc1234-111"
      assert merged.load_balancer_attached? === true
      assert merged.target_group_arns === ["arn:aws:tg/1"]
      assert merged.use_public_ip_cert? === true
    end
  end

  describe "to_json/1 and from_json/1 with new fields" do
    test "round-trip preserves instance_tag and git_branch" do
      original = %QaNode{
        instance_id: "i-0abc123def456",
        app_name: "my_app",
        target_sha: "abc1234567890",
        instance_tag: "my-feature",
        git_branch: "feat/my-feature",
        load_balancer_attached?: false,
        target_group_arns: []
      }

      round_tripped = original |> QaNode.to_json() |> QaNode.from_json()

      assert round_tripped.instance_tag === "my-feature"
      assert round_tripped.git_branch === "feat/my-feature"
    end

    test "from_json on old JSON missing new keys produces nil for those fields" do
      old_json = ~s({
        "version": 1,
        "instance_id": "i-0abc123",
        "app_name": "my_app",
        "target_sha": "abc1234",
        "load_balancer_attached": false,
        "target_group_arns": []
      })

      qa_node = QaNode.from_json(old_json)

      assert is_nil(qa_node.instance_tag)
      assert is_nil(qa_node.git_branch)
    end

    test "to_json includes instance_tag and git_branch keys" do
      qa_node = %QaNode{
        app_name: "my_app",
        target_sha: "abc1234",
        instance_tag: "v2",
        git_branch: "main",
        load_balancer_attached?: false,
        target_group_arns: []
      }

      decoded = qa_node |> QaNode.to_json() |> Jason.decode!()

      assert decoded["instance_tag"] === "v2"
      assert decoded["git_branch"] === "main"
    end
  end

  describe "build_qa_node_from_instance/1" do
    test "extracts InstanceTag and GitBranch from EC2 tags" do
      instance = %{
        "instanceId" => "i-0abc123",
        "ipAddress" => "54.1.2.3",
        "privateIpAddress" => "10.0.0.1",
        "launchTime" => "2024-01-15T10:00:00Z",
        "instanceState" => %{"name" => "running"},
        "tagSet" => %{
          "item" => [
            %{"key" => "InstanceGroup", "value" => "my_app_prod"},
            %{"key" => "TargetSha", "value" => "abc1234567"},
            %{"key" => "Name", "value" => "my_app-prod-qa-abc1234-1234567"},
            %{"key" => "InstanceTag", "value" => "my-feature"},
            %{"key" => "GitBranch", "value" => "feat/my-feature"}
          ]
        }
      }

      qa_node = QaNode.build_qa_node_from_instance(instance)

      assert qa_node.instance_tag === "my-feature"
      assert qa_node.git_branch === "feat/my-feature"
    end

    test "instance without InstanceTag or GitBranch tags produces nil for those fields" do
      instance = %{
        "instanceId" => "i-0abc123",
        "ipAddress" => nil,
        "privateIpAddress" => nil,
        "launchTime" => "2024-01-15T10:00:00Z",
        "instanceState" => %{"name" => "running"},
        "tagSet" => %{
          "item" => [
            %{"key" => "InstanceGroup", "value" => "my_app_prod"},
            %{"key" => "TargetSha", "value" => "abc1234567"}
          ]
        }
      }

      qa_node = QaNode.build_qa_node_from_instance(instance)

      assert is_nil(qa_node.instance_tag)
      assert is_nil(qa_node.git_branch)
    end
  end

  describe "sanitize_tag/1" do
    test "leaves already-clean tags unchanged" do
      assert QaNode.sanitize_tag("my-feature") === "my-feature"
    end

    test "lowercases and replaces spaces with hyphens" do
      assert QaNode.sanitize_tag("My Feature") === "my-feature"
    end

    test "replaces underscores with hyphens" do
      assert QaNode.sanitize_tag("feature_123") === "feature-123"
    end

    test "strips characters not in [a-z0-9-]" do
      assert QaNode.sanitize_tag("!!!") === ""
    end

    test "returns nil for nil input" do
      assert QaNode.sanitize_tag(nil) === nil
    end
  end

  describe "ansible_limit_pattern/1" do
    test "returns an instance-id glob safe for ansible --limit even when the Name tag has whitespace" do
      qa_node = %QaNode{
        instance_id: "i-0abc123",
        instance_name: "CFX Web-prod-qa-foo-1700000000"
      }

      assert QaNode.ansible_limit_pattern(qa_node) === "i-0abc123*"
    end
  end

  describe "pick_interactive/2" do
    test "returns {:ok, []} for empty list" do
      assert QaNode.pick_interactive([]) === {:ok, []}
    end

    test "returns {:ok, [node]} for single-node list without prompting" do
      node = %QaNode{
        instance_id: "i-0abc123",
        app_name: "my_app",
        target_sha: "abc1234567890",
        load_balancer_attached?: false,
        target_group_arns: []
      }

      assert QaNode.pick_interactive([node]) === {:ok, [node]}
    end
  end

  describe "format_picker_label (via pick_interactive)" do
    test "label includes instance_name, instance_id, short sha, and branch" do
      node = %QaNode{
        instance_id: "i-0abc123",
        instance_name: "my_app-prod-qa-abc1234-111",
        app_name: "my_app",
        target_sha: "abc1234567890",
        git_branch: "feat/my-feature",
        instance_tag: nil,
        load_balancer_attached?: false,
        target_group_arns: []
      }

      # Call format_picker_label via the public build of pick_interactive label logic.
      # We use a single node so it returns without prompting, then verify the label format
      # by calling the public function directly.
      label = QaNode.format_picker_label(node)

      assert label =~ "my_app-prod-qa-abc1234-111"
      assert label =~ "i-0abc123"
      assert label =~ "abc1234"
      assert label =~ "feat/my-feature"
    end

    test "label includes instance_tag in brackets when present" do
      node = %QaNode{
        instance_id: "i-0abc123",
        instance_name: "my_app-prod-qa-my-feature-111",
        app_name: "my_app",
        target_sha: "abc1234567890",
        git_branch: "main",
        instance_tag: "my-feature",
        load_balancer_attached?: false,
        target_group_arns: []
      }

      label = QaNode.format_picker_label(node)

      assert label =~ "[my-feature]"
    end

    test "label uses em-dash for missing git_branch" do
      node = %QaNode{
        instance_id: "i-0abc123",
        instance_name: "my_app-prod-qa-abc1234-111",
        app_name: "my_app",
        target_sha: "abc1234567890",
        git_branch: nil,
        instance_tag: nil,
        load_balancer_attached?: false,
        target_group_arns: []
      }

      label = QaNode.format_picker_label(node)

      assert label =~ "branch: —"
    end

    test "label uses app_name when instance_name is nil" do
      node = %QaNode{
        instance_id: "i-0abc123",
        instance_name: nil,
        app_name: "my_app",
        target_sha: "abc1234567890",
        git_branch: nil,
        instance_tag: nil,
        load_balancer_attached?: false,
        target_group_arns: []
      }

      label = QaNode.format_picker_label(node)

      assert label =~ "my_app"
    end
  end

  describe "select_by_branch/2" do
    test "returns the single matching node" do
      a = %QaNode{instance_id: "i-aaa", git_branch: "qa/cfx_web-canary"}
      b = %QaNode{instance_id: "i-bbb", git_branch: "qa/cfx_web-other"}

      assert {:ok, %QaNode{instance_id: "i-aaa"}} =
               QaNode.select_by_branch([a, b], "qa/cfx_web-canary")
    end

    test "returns :not_found when no node matches" do
      a = %QaNode{instance_id: "i-aaa", git_branch: "qa/cfx_web-canary"}

      assert {:error, %ErrorMessage{code: :not_found, message: msg}} =
               QaNode.select_by_branch([a], "qa/cfx_web-other")

      assert msg =~ "qa/cfx_web-other"
    end

    test "returns :conflict when multiple nodes share the branch" do
      a = %QaNode{instance_id: "i-aaa", git_branch: "qa/cfx_web-canary"}
      b = %QaNode{instance_id: "i-bbb", git_branch: "qa/cfx_web-canary"}

      assert {:error, %ErrorMessage{code: :conflict, details: details}} =
               QaNode.select_by_branch([a, b], "qa/cfx_web-canary")

      assert details.instance_ids === ["i-aaa", "i-bbb"]
    end

    test "returns :not_found for empty node list" do
      assert {:error, %ErrorMessage{code: :not_found}} =
               QaNode.select_by_branch([], "qa/cfx_web-canary")
    end
  end
end
