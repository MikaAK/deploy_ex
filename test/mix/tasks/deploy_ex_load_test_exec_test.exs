defmodule Mix.Tasks.DeployEx.LoadTest.ExecTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.DeployEx.LoadTest.Exec

  defmodule FakeK6RunnerTerminated do
    def fetch_all_runners(_opts), do: {:ok, [%DeployEx.K6Runner{instance_id: "i-dead"}]}
    def fetch_state(_instance_id, _opts), do: {:ok, %DeployEx.K6Runner{instance_id: "i-dead"}}
    def verify_instance_exists(_runner), do: {:ok, nil}
  end

  defmodule FakeK6RunnerAbsent do
    def fetch_all_runners(_opts), do: {:ok, []}
    def fetch_state(_instance_id, _opts), do: {:ok, nil}
    def verify_instance_exists(_runner), do: {:ok, nil}
  end

  defmodule FakeK6RunnerFetchYieldsNil do
    def fetch_all_runners(_opts), do: {:ok, nil}
    def fetch_state(_instance_id, _opts), do: {:ok, nil}
    def verify_instance_exists(_runner), do: {:ok, nil}
  end

  defmodule FakeK6RunnerActive do
    def fetch_all_runners(_opts) do
      {:ok, [%DeployEx.K6Runner{instance_id: "i-live", public_ip: "1.2.3.4"}]}
    end

    def fetch_state(_instance_id, _opts) do
      {:ok, %DeployEx.K6Runner{instance_id: "i-live", public_ip: "1.2.3.4"}}
    end

    def verify_instance_exists(runner), do: {:ok, %{runner | state: "running"}}
  end

  describe "resolve_runner/2 default path (no --instance-id)" do
    test "returns a not_found error naming create_instance when the only runner is terminated" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Exec.resolve_runner([], FakeK6RunnerTerminated)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "returns a not_found error naming create_instance when no runners exist" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Exec.resolve_runner([], FakeK6RunnerAbsent)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "returns the verified runner when active" do
      assert {:ok, %DeployEx.K6Runner{instance_id: "i-live", state: "running"}} =
               Exec.resolve_runner([], FakeK6RunnerActive)
    end

    test "returns a not_found error naming create_instance when fetch_all_runners itself yields nil" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Exec.resolve_runner([], FakeK6RunnerFetchYieldsNil)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end
  end

  describe "resolve_runner/2 --instance-id path" do
    test "returns a not_found error naming create_instance for a terminated runner" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Exec.resolve_runner([instance_id: "i-dead"], FakeK6RunnerTerminated)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "returns a not_found error naming create_instance when instance id has no saved state" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Exec.resolve_runner([instance_id: "i-missing"], FakeK6RunnerAbsent)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "returns the verified runner for a live instance id" do
      assert {:ok, %DeployEx.K6Runner{instance_id: "i-live", state: "running"}} =
               Exec.resolve_runner([instance_id: "i-live"], FakeK6RunnerActive)
    end
  end

  describe "resolve_prometheus_url/2" do
    test "uses --prometheus-url flag when provided, skipping discovery entirely" do
      discover = fn -> flunk("discovery must not run when --prometheus-url is set") end

      assert {:ok, "http://10.0.1.99:9090"} =
               Exec.resolve_prometheus_url([prometheus_url: "http://10.0.1.99:9090"], discover)
    end

    test "discovers the prometheus node's private ip when no flag is given" do
      discover = fn -> {:ok, "10.0.101.171"} end

      assert {:ok, "http://10.0.101.171:9090"} = Exec.resolve_prometheus_url([], discover)
    end

    test "returns nil when discovery finds no prometheus node" do
      discover = fn -> {:error, :not_found} end

      assert {:ok, nil} = Exec.resolve_prometheus_url([], discover)
    end
  end

  describe "ssh_target/2 — SSH user via Cloud.ssh_user/1 (LT-OCI S1)" do
    test "defaults to admin@ip under the AWS provider (unchanged AWS behavior)" do
      assert Exec.ssh_target("1.2.3.4", []) === "admin@1.2.3.4"
    end

    test "resolves ubuntu@ip for an overridden provider" do
      assert Exec.ssh_target("1.2.3.4", provider: :oci) === "ubuntu@1.2.3.4"
    end
  end

  describe "build_k6_command/3" do
    test "includes TARGET_URL and K6_PROMETHEUS_RW_SERVER_URL with the -o flag when both are configured" do
      command = Exec.build_k6_command("load_test.js", "http://10.0.101.171:9090", "http://app:4000")

      assert command =~ "TARGET_URL=http://app:4000"
      assert command =~ "K6_PROMETHEUS_RW_SERVER_URL=http://10.0.101.171:9090/api/v1/write"
      assert command === "TARGET_URL=http://app:4000 K6_PROMETHEUS_RW_SERVER_URL=http://10.0.101.171:9090/api/v1/write k6 run -o experimental-prometheus-rw /srv/k6/scripts/load_test.js"
    end

    test "omits the -o flag and K6_PROMETHEUS_RW_SERVER_URL when prometheus_url is nil" do
      command = Exec.build_k6_command("load_test.js", nil, "http://app:4000")

      assert command === "TARGET_URL=http://app:4000 k6 run /srv/k6/scripts/load_test.js"
      refute command =~ "K6_PROMETHEUS_RW_SERVER_URL"
      refute command =~ "-o experimental-prometheus-rw"
    end

    test "omits TARGET_URL when target_url is nil" do
      command = Exec.build_k6_command("load_test.js", "http://10.0.101.171:9090", nil)

      assert command === "K6_PROMETHEUS_RW_SERVER_URL=http://10.0.101.171:9090/api/v1/write k6 run -o experimental-prometheus-rw /srv/k6/scripts/load_test.js"
      refute command =~ "TARGET_URL"
    end
  end
end
