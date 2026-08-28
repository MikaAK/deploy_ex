defmodule DeployEx.K6RunnerTest do
  use ExUnit.Case, async: true

  alias DeployEx.K6Runner

  defmodule ResolveFakeTerminated do
    def fetch_all_runners(_opts), do: {:ok, [%K6Runner{instance_id: "i-dead"}]}
    def fetch_state(_instance_id, _opts), do: {:ok, %K6Runner{instance_id: "i-dead"}}
    def verify_instance_exists(_runner, _opts \\ []), do: {:ok, nil}
  end

  defmodule ResolveFakeAbsent do
    def fetch_all_runners(_opts), do: {:ok, []}
    def fetch_state(_instance_id, _opts), do: {:ok, nil}
    def verify_instance_exists(_runner, _opts \\ []), do: {:ok, nil}
  end

  defmodule ResolveFakeFetchYieldsNil do
    def fetch_all_runners(_opts), do: {:ok, nil}
    def fetch_state(_instance_id, _opts), do: {:ok, nil}
    def verify_instance_exists(_runner, _opts \\ []), do: {:ok, nil}
  end

  defmodule ResolveFakeActive do
    def fetch_all_runners(_opts), do: {:ok, [%K6Runner{instance_id: "i-live"}]}
    def fetch_state(_instance_id, _opts), do: {:ok, %K6Runner{instance_id: "i-live"}}
    def verify_instance_exists(runner, _opts \\ []), do: {:ok, %{runner | state: "running"}}
  end

  defmodule ResolveOptsCapture do
    @moduledoc """
    Captures the opts resolve_runner/2 passes into verify_instance_exists — closes the class
    of bug where a dropped-opts call site can't be caught by a contract test that passes
    `provider: :oci` directly to verify_instance_exists itself (LT-OCI review-fix cycle 2).
    """

    def fetch_all_runners(_opts), do: {:ok, [%K6Runner{instance_id: "i-opts-capture"}]}
    def fetch_state(_instance_id, _opts), do: {:ok, %K6Runner{instance_id: "i-opts-capture"}}

    def verify_instance_exists(runner, opts) do
      send(self(), {:verify_instance_exists_called, runner, opts})
      {:ok, %{runner | state: "running"}}
    end
  end

  defp line_index(script, regex) do
    script
    |> String.split("\n")
    |> Enum.find_index(&(&1 =~ regex))
  end

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

  describe "K6Runner :oci contract — not_implemented vs OCI-routed (LT-OCI review-fix)" do
    test "machine ops are not_implemented under :oci — the Machine capability is not wired yet" do
      runner = %K6Runner{instance_id: "i-contract-1"}

      assert {:error, %ErrorMessage{code: :not_implemented}} =
               K6Runner.create_instance(%{}, provider: :oci)

      assert {:error, %ErrorMessage{code: :not_implemented}} =
               K6Runner.terminate_instance("i-contract-1", provider: :oci)

      assert {:error, %ErrorMessage{code: :not_implemented}} =
               K6Runner.verify_instance_exists(runner, provider: :oci)

      assert {:error, %ErrorMessage{code: :not_implemented}} =
               K6Runner.find_runners_from_ec2(provider: :oci)
    end

    test "state ops route to OciObjectStore — blocked only by unset release_bucket, never :not_implemented" do
      results = [
        save_state: K6Runner.save_state(%K6Runner{instance_id: "i-contract-2"}, provider: :oci),
        fetch_state: K6Runner.fetch_state("i-contract-2", provider: :oci),
        fetch_all_runners: K6Runner.fetch_all_runners(provider: :oci),
        delete_state: K6Runner.delete_state("i-contract-2", provider: :oci)
      ]

      Enum.each(results, fn {label, result} ->
        assert {:error, %ErrorMessage{code: :bad_request}} = result,
               "#{label} under :oci expected :bad_request (unset release_bucket), got #{inspect(result)}"
      end)
    end

    test "with a CONFIGURED oci bucket and a real stored runner, resolve_runner reaches :not_implemented cleanly — never AWS (review cycle 2 item 3)" do
      # Simulates the exact reviewer-measured scenario: bucket configured (via the explicit
      # :bucket opt, bypassing the unset-namespace error) and a runner actually on disk, proving
      # resolution stops at the not-yet-wired machine capability instead of silently falling
      # through to AwsMachine/EC2 and, on a miss there, deleting the real OCI state object.
      stored_runner = %K6Runner{instance_id: "i-oci-stored", state: "running"}

      run_fn = fn command, _cwd ->
        cond do
          command =~ "os object list" ->
            {:ok, Jason.encode!(%{"data" => [%{"name" => "k6-runners/i-oci-stored.json"}]})}

          command =~ "os object get" ->
            [_match, path] = Regex.run(~r/--file '([^']+)'/, command)
            File.write!(path, K6Runner.to_json(stored_runner))
            {:ok, ""}

          true ->
            flunk("unexpected oci command: #{command}")
        end
      end

      assert {:error, %ErrorMessage{code: :not_implemented}} =
               K6Runner.resolve_runner([provider: :oci, bucket: "configured-bucket", run_fn: run_fn], K6Runner)
    end
  end

  describe "verify_instance_exists/2 (routed through Cloud.capability(:machine) — LT-OCI review-fix)" do
    defp describe_instance_response(instance_id, state, private_ip) do
      "<DescribeInstancesResponse><reservationSet><item><instancesSet><item>" <>
        "<instanceId>#{instance_id}</instanceId>" <>
        "<instanceState><name>#{state}</name></instanceState>" <>
        "<privateIpAddress>#{private_ip}</privateIpAddress>" <>
        "</item></instancesSet></item></reservationSet></DescribeInstancesResponse>"
    end

    defp describe_instance_not_found_response do
      "<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>"
    end

    test "returns {:ok, nil} for nil input, opts ignored" do
      assert K6Runner.verify_instance_exists(nil, provider: :oci) === {:ok, nil}
    end

    test "found instance: maps the normalized Instance struct fields onto the runner" do
      request_fn = fn _request, _config ->
        {:ok, %{body: describe_instance_response("i-found-1", "running", "10.0.0.5")}}
      end

      runner = %K6Runner{instance_id: "i-found-1"}

      assert {:ok, %K6Runner{instance_id: "i-found-1", state: "running", private_ip: "10.0.0.5"}} =
               K6Runner.verify_instance_exists(runner, request_fn: request_fn)
    end

    test "does NOT leak the caller's opts (e.g. a --pem path) into the downstream EC2 request params (G1 leak class, end-to-end)" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: describe_instance_response("i-found-2", "running", "10.0.0.6")}}
      end

      runner = %K6Runner{instance_id: "i-found-2"}

      K6Runner.verify_instance_exists(runner,
        request_fn: request_fn,
        pem: "/secret/path/key.pem",
        quiet: true
      )

      assert_received {:ec2_request, %ExAws.Operation.Query{params: params}}
      refute Map.has_key?(params, "Pem")
      refute Map.has_key?(params, "Quiet")
    end

    test "not found: deletes the stale state and returns {:ok, nil}" do
      request_fn = fn
        %ExAws.Operation.Query{}, _config ->
          {:ok, %{body: describe_instance_not_found_response()}}

        %ExAws.Operation.S3{} = request, _config ->
          send(self(), {:s3_delete_request, request})
          {:ok, %{body: ""}}
      end

      runner = %K6Runner{instance_id: "i-stale-1"}

      assert {:ok, nil} = K6Runner.verify_instance_exists(runner, request_fn: request_fn)
      assert_received {:s3_delete_request, %ExAws.Operation.S3{http_method: :delete}}
    end

    test "not found, but the state delete itself fails: propagates the error rather than crashing" do
      request_fn = fn
        %ExAws.Operation.Query{}, _config ->
          {:ok, %{body: describe_instance_not_found_response()}}

        %ExAws.Operation.S3{}, _config ->
          {:error, {:http_error, 500, %{body: "boom"}}}
      end

      runner = %K6Runner{instance_id: "i-stale-delete-fails"}

      assert {:error, %ErrorMessage{}} = K6Runner.verify_instance_exists(runner, request_fn: request_fn)
    end

    test "capability not implemented (e.g. under :oci): propagates the error WITHOUT deleting state (cross-provider leak guard)" do
      runner = %K6Runner{instance_id: "i-oci-1"}

      assert {:error, %ErrorMessage{code: :not_implemented}} =
               K6Runner.verify_instance_exists(runner, provider: :oci)
    end
  end

  describe "build_user_data/0 (D1: debian-13 compatibility)" do
    setup do
      %{script: K6Runner.build_user_data()}
    end

    test "does not invoke ec2-metadata (Amazon Linux-only, absent on debian-13)", %{script: script} do
      refute script =~ "ec2-metadata"
    end

    test "does not shell out to the aws CLI (not installed on the debian-13 base AMI)", %{script: script} do
      refute script =~ ~r/\baws\s+ec2\b/
    end

    test "installs curl before curl is invoked", %{script: script} do
      install_index = line_index(script, ~r/^apt-get install.*\bcurl\b/)
      usage_index = line_index(script, ~r/^curl\s/)

      refute is_nil(install_index)
      refute is_nil(usage_index)
      assert install_index < usage_index
    end

    test "installs gnupg before gpg is invoked", %{script: script} do
      install_index = line_index(script, ~r/^apt-get install.*\bgnupg\b/)
      usage_index = line_index(script, ~r/gpg --dearmor/)

      refute is_nil(install_index)
      refute is_nil(usage_index)
      assert install_index < usage_index
    end

    test "installs k6 via apt before verifying its version", %{script: script} do
      install_index = line_index(script, ~r/^apt-get install.*\bk6\b/)
      version_index = line_index(script, ~r/^k6 version$/)

      refute is_nil(install_index)
      refute is_nil(version_index)
      assert install_index < version_index
    end

    test "creates /srv/k6/scripts", %{script: script} do
      assert script =~ "mkdir -p /srv/k6/scripts"
    end

    test "makes /srv/k6 writable by the admin ssh user before setup completes (D2)", %{script: script} do
      mkdir_index = line_index(script, ~r{^mkdir -p /srv/k6/scripts$})
      chown_index = line_index(script, ~r/^chown.*admin.*\/srv\/k6/)

      refute is_nil(chown_index)
      assert mkdir_index < chown_index
    end

    test "aborts on first failing command", %{script: script} do
      assert script =~ "set -euo pipefail"
    end

    test "every apt-get invocation is lock-tolerant (fresh-boot dpkg lock hardening)", %{script: script} do
      apt_get_lines =
        script
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "apt-get"))

      refute Enum.empty?(apt_get_lines)

      Enum.each(apt_get_lines, fn line ->
        assert line =~ "DPkg::Lock::Timeout", "expected #{inspect(line)} to be lock-tolerant"
      end)
    end
  end

  describe "save_state/2 (routed through Cloud.capability(:object_store) — LT-OCI S1)" do
    test "puts to the resolved release bucket at the state key" do
      runner = %K6Runner{instance_id: "i-save-1"}

      request_fn = fn request, _config ->
        send(self(), {:s3_request, request})
        {:ok, %{body: ""}}
      end

      assert {:ok, :saved} = K6Runner.save_state(runner, request_fn: request_fn)

      assert_received {:s3_request, %ExAws.Operation.S3{bucket: bucket, path: path, http_method: :put}}
      assert bucket === DeployEx.Config.aws_release_bucket()
      assert path === "k6-runners/i-save-1.json"
    end

    test "an explicit :bucket opt overrides the resolved default" do
      runner = %K6Runner{instance_id: "i-save-2"}

      request_fn = fn request, _config ->
        send(self(), {:s3_request, request})
        {:ok, %{body: ""}}
      end

      K6Runner.save_state(runner, request_fn: request_fn, bucket: "custom-bucket")

      assert_received {:s3_request, %ExAws.Operation.S3{bucket: "custom-bucket"}}
    end
  end

  describe "fetch_state/2 (routed through Cloud.capability(:object_store) — LT-OCI S1)" do
    test "decodes a found state object into a K6Runner struct" do
      request_fn = fn _request, _config ->
        {:ok, %{body: K6Runner.to_json(%K6Runner{instance_id: "i-fetch-1", state: "running"})}}
      end

      assert {:ok, %K6Runner{instance_id: "i-fetch-1", state: "running"}} =
               K6Runner.fetch_state("i-fetch-1", request_fn: request_fn)
    end

    test "resolves a missing state object to {:ok, nil} rather than an error" do
      request_fn = fn _request, _config ->
        {:error, {:http_error, 404, %{body: ""}}}
      end

      assert {:ok, nil} = K6Runner.fetch_state("i-fetch-missing", request_fn: request_fn)
    end
  end

  describe "delete_state/2 (routed through Cloud.capability(:object_store) — LT-OCI S1)" do
    test "deletes the state object at the resolved bucket and key" do
      request_fn = fn request, _config ->
        send(self(), {:s3_request, request})
        {:ok, %{body: ""}}
      end

      assert :ok = K6Runner.delete_state("i-delete-1", request_fn: request_fn)

      assert_received {:s3_request, %ExAws.Operation.S3{path: "k6-runners/i-delete-1.json", http_method: :delete}}
    end

    test "treats a 404 from the object store as a successful idempotent delete (D-regression)" do
      request_fn = fn _request, _config ->
        {:error, {:http_error, 404, %{body: ""}}}
      end

      assert :ok = K6Runner.delete_state("i-already-gone", request_fn: request_fn)
    end
  end

  describe "bucket resolution errors loudly instead of proceeding with nil (LT-OCI review-fix)" do
    test "save_state propagates a bad_request instead of writing to an empty container name" do
      runner = %K6Runner{instance_id: "i-unset-bucket"}

      assert {:error, %ErrorMessage{code: :bad_request, message: message}} =
               K6Runner.save_state(runner, provider: :oci)

      assert message =~ "release_bucket"
    end

    test "an explicit :bucket opt still bypasses the Cloud lookup entirely, even under a provider with no configured bucket" do
      runner = %K6Runner{instance_id: "i-explicit-bucket"}

      # provider: :oci routes save_state through OciObjectStore (its DI seam is :run_fn, not
      # ExAws's :request_fn) — :oci has no configured release_bucket in test config at all, so
      # a successful save here can only mean the explicit :bucket opt was used directly, never
      # routed through Cloud.release_bucket(provider: :oci) (which errors for this exact config).
      run_fn = fn command, _cwd ->
        send(self(), {:oci_command, command})
        {:ok, ""}
      end

      assert {:ok, :saved} =
               K6Runner.save_state(runner, provider: :oci, bucket: "explicit-bucket", run_fn: run_fn)

      assert_received {:oci_command, command}
      assert command =~ "--bucket-name 'explicit-bucket'"
    end

    test "fetch_state propagates a bad_request instead of reading from an empty container name" do
      assert {:error, %ErrorMessage{code: :bad_request}} =
               K6Runner.fetch_state("i-unset-bucket", provider: :oci)
    end

    test "fetch_all_runners propagates a bad_request instead of listing an empty container name" do
      assert {:error, %ErrorMessage{code: :bad_request}} = K6Runner.fetch_all_runners(provider: :oci)
    end

    test "delete_state propagates a bad_request instead of deleting from an empty container name" do
      assert {:error, %ErrorMessage{code: :bad_request}} =
               K6Runner.delete_state("i-unset-bucket", provider: :oci)
    end
  end

  describe "create_instance/2 (routed through Cloud.capability(:machine) — LT-OCI S1)" do
    defp run_instances_response(instance_id) do
      "<RunInstancesResponse><instancesSet><item>" <>
        "<instanceId>#{instance_id}</instanceId>" <>
        "</item></instancesSet></RunInstancesResponse>"
    end

    test "no --instance-type override: the spec carries no default, AWS still ends up with t3.small (LT-OCI S2)" do
      # instance_type defaults used to live in K6Runner (AWS-flavored "t3.small") and leaked
      # into every provider's neutral spec. Moving the default into each provider's own
      # run_instance/2 (AwsMachine falls back to "t3.small", OciMachine to its own shape
      # default) means the spec itself carries nil when the caller gave no override, and each
      # adapter picks its own honest default instead of inheriting AWS's.
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: run_instances_response("i-default-type")}}
      end

      assert {:ok, %K6Runner{instance_id: "i-default-type"}} =
               K6Runner.create_instance(%{}, request_fn: request_fn)

      assert_received {:ec2_request, %ExAws.Operation.Query{params: ec2_params}}
      assert ec2_params["InstanceType"] === "t3.small"
    end

    test "creates the instance via the machine capability and returns a K6Runner" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: run_instances_response("i-created-1")}}
      end

      params = %{
        key_name: "my-key",
        subnet_id: "subnet-123",
        security_group_id: "sg-123",
        ami_id: "ami-123",
        iam_instance_profile: "profile-name",
        instance_type: "t3.medium"
      }

      assert {:ok, %K6Runner{instance_id: "i-created-1", instance_name: instance_name}} =
               K6Runner.create_instance(params, request_fn: request_fn)

      refute is_nil(instance_name)

      assert_received {:ec2_request, %ExAws.Operation.Query{params: ec2_params}}
      assert ec2_params["InstanceType"] === "t3.medium"
      assert ec2_params["ImageId"] === "ami-123"
      assert ec2_params["TagSpecification.1.Tag.1.Key"] === "Name"
      assert ec2_params["TagSpecification.1.Tag.2.Key"] === "Group"
      assert {:ok, expected_resource_group} = DeployEx.Cloud.resource_group([])
      assert ec2_params["TagSpecification.1.Tag.2.Value"] === expected_resource_group
    end
  end

  describe "terminate_instance/2 (routed through Cloud.capability(:machine) — LT-OCI S1)" do
    test "terminates via the machine capability" do
      request_fn = fn request, _config ->
        send(self(), {:ec2_request, request})
        {:ok, %{body: "<TerminateInstancesResponse></TerminateInstancesResponse>"}}
      end

      assert :ok = K6Runner.terminate_instance("i-terminate-1", request_fn: request_fn)

      assert_received {:ec2_request, %ExAws.Operation.Query{action: :terminate_instances}}
    end
  end

  describe "build_user_data/1 ssh user (LT-OCI S1)" do
    test "defaults to admin under the AWS provider (unchanged AWS behavior)" do
      assert K6Runner.build_user_data() =~ ~r/chown -R admin:admin \/srv\/k6/
    end

    test "resolves through Cloud.ssh_user/1 for an overridden provider" do
      assert K6Runner.build_user_data(provider: :oci) =~ ~r/chown -R ubuntu:ubuntu \/srv\/k6/
    end
  end

  describe "resolve_runner/2 (shared runner resolution, extracted for LT-FIX-A)" do
    test "default path: returns a not_found error naming create_instance for a terminated-only runner" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               K6Runner.resolve_runner([], ResolveFakeTerminated)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "default path: returns a not_found error naming create_instance when no runners exist" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               K6Runner.resolve_runner([], ResolveFakeAbsent)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "default path: returns a not_found error naming create_instance when fetch_all_runners yields nil" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               K6Runner.resolve_runner([], ResolveFakeFetchYieldsNil)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "default path: returns the verified runner when active" do
      assert {:ok, %K6Runner{instance_id: "i-live", state: "running"}} =
               K6Runner.resolve_runner([], ResolveFakeActive)
    end

    test "--instance-id path: returns a not_found error naming create_instance for a terminated runner" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               K6Runner.resolve_runner([instance_id: "i-dead"], ResolveFakeTerminated)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "--instance-id path: returns a not_found error naming create_instance when no saved state exists" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               K6Runner.resolve_runner([instance_id: "i-missing"], ResolveFakeAbsent)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "--instance-id path: returns the verified runner for a live instance id" do
      assert {:ok, %K6Runner{instance_id: "i-live", state: "running"}} =
               K6Runner.resolve_runner([instance_id: "i-live"], ResolveFakeActive)
    end
  end

  describe "resolve_runner/2 threads opts into verify_instance_exists (LT-OCI review-fix cycle 2)" do
    test "default path: a :provider override reaches verify_instance_exists, not just fetch_all_runners" do
      K6Runner.resolve_runner([provider: :oci], ResolveOptsCapture)

      assert_received {:verify_instance_exists_called, _runner, opts}
      assert opts[:provider] === :oci
    end

    test "--instance-id path: a :provider override reaches verify_instance_exists, not just fetch_state" do
      K6Runner.resolve_runner([provider: :oci, instance_id: "i-opts-capture"], ResolveOptsCapture)

      assert_received {:verify_instance_exists_called, _runner, opts}
      assert opts[:provider] === :oci
    end
  end

  # Behavioural pagination tests. Responses are queued in the process dictionary — per-PID
  # isolated, no setup/teardown. Mirrors test/deploy_ex/cloud/pagination_test.exs: replacing the
  # recursion with a single request makes these red.
  describe "find_runners_from_ec2/1 provider guard (LT-OCI review-fix)" do
    test "errors instead of paginating EC2 under a non-AWS provider (must not print AWS runners as OCI)" do
      assert {:error, %ErrorMessage{code: :not_implemented}} =
               K6Runner.find_runners_from_ec2(provider: :oci)
    end

    test "does not touch ExAws at all under a non-AWS provider" do
      request_fn = fn _request, _config ->
        flunk("find_runners_from_ec2 must not call ExAws under a non-AWS provider")
      end

      K6Runner.find_runners_from_ec2(provider: :oci, request_fn: request_fn)
    end

    test "the descriptor MODULE override for AWS still paginates (F1 recurrence guard, review-fix cycle 3)" do
      request_fn = fn _request, _config ->
        {:ok, %{body: "<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>"}}
      end

      assert {:ok, []} =
               K6Runner.find_runners_from_ec2(provider: DeployEx.Cloud.Providers.Aws, request_fn: request_fn)
    end
  end

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
