defmodule Mix.Tasks.DeployEx.LoadTest.UploadTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.DeployEx.LoadTest.Upload

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

  describe "scp_target/3 — SSH user via Cloud.ssh_user/1 (LT-OCI S1)" do
    test "defaults to admin@ip:path under the AWS provider (unchanged AWS behavior)" do
      assert Upload.scp_target("1.2.3.4", "/srv/k6/scripts/load_test.js", []) ===
               "admin@1.2.3.4:/srv/k6/scripts/load_test.js"
    end

    test "resolves ubuntu@ip:path for an overridden provider" do
      assert Upload.scp_target("1.2.3.4", "/srv/k6/scripts/load_test.js", provider: :oci) ===
               "ubuntu@1.2.3.4:/srv/k6/scripts/load_test.js"
    end
  end

  describe "resolve_runner/2 default path (no --instance-id)" do
    test "returns a not_found error naming create_instance when the only runner is terminated" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Upload.resolve_runner([], FakeK6RunnerTerminated)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "returns a not_found error naming create_instance when no runners exist" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Upload.resolve_runner([], FakeK6RunnerAbsent)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "returns the verified runner when active" do
      assert {:ok, %DeployEx.K6Runner{instance_id: "i-live", state: "running"}} =
               Upload.resolve_runner([], FakeK6RunnerActive)
    end

    test "returns a not_found error naming create_instance when fetch_all_runners itself yields nil" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Upload.resolve_runner([], FakeK6RunnerFetchYieldsNil)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end
  end

  describe "resolve_runner/2 --instance-id path" do
    test "returns a not_found error naming create_instance for a terminated runner" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Upload.resolve_runner([instance_id: "i-dead"], FakeK6RunnerTerminated)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "returns a not_found error naming create_instance when instance id has no saved state" do
      assert {:error, %ErrorMessage{code: :not_found, message: message}} =
               Upload.resolve_runner([instance_id: "i-missing"], FakeK6RunnerAbsent)

      assert message =~ "mix deploy_ex.load_test.create_instance"
    end

    test "returns the verified runner for a live instance id" do
      assert {:ok, %DeployEx.K6Runner{instance_id: "i-live", state: "running"}} =
               Upload.resolve_runner([instance_id: "i-live"], FakeK6RunnerActive)
    end
  end
end
