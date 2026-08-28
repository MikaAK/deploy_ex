defmodule Mix.Tasks.DeployEx.LoadTest.CreateInstanceTest do
  use ExUnit.Case, async: true

  alias DeployEx.K6Runner
  alias Mix.Tasks.DeployEx.LoadTest.CreateInstance

  defmodule FakeK6RunnerOrphaned do
    def fetch_state(_instance_id, _opts), do: {:ok, %K6Runner{instance_id: "i-orphan"}}
    def verify_instance_exists(_runner, _opts \\ []), do: {:ok, nil}

    def save_state(runner, _opts) do
      send(self(), {:save_state_called, runner.instance_id})
      {:ok, :saved}
    end
  end

  defmodule FakeK6RunnerHealthy do
    def fetch_state(_instance_id, _opts), do: {:ok, %K6Runner{instance_id: "i-healthy"}}
    def verify_instance_exists(runner, _opts \\ []), do: {:ok, %{runner | state: "running"}}
    def save_state(_runner, _opts), do: {:ok, :saved}
  end

  describe "parse_args/1 — --provider CLI flag (LT-OCI review-fix item 7)" do
    test "a valid --provider flag is converted to an atom in the returned opts" do
      {opts, _extra_args} = CreateInstance.parse_args(["--provider", "oci"])

      assert opts[:provider] === :oci
    end

    test "no --provider flag leaves :provider absent (defaults resolve through Cloud.active_provider/1 later)" do
      {opts, _extra_args} = CreateInstance.parse_args(["--instance-type", "t3.medium"])

      refute Keyword.has_key?(opts, :provider)
    end

    test "an unrecognized --provider value raises Mix.Error instead of silently running against AWS" do
      assert_raise Mix.Error, ~r/gcp/, fn ->
        CreateInstance.parse_args(["--provider", "gcp"])
      end
    end
  end

  describe "gather_infrastructure/1 — routes through Cloud.capability(:infrastructure), keeps :run_fn/:pem (LT-OCI S2)" do
    test "under :oci, a run_fn/oci config override reaches OciInfrastructure end-to-end" do
      opts = [
        provider: :oci,
        oci_subnet_id: "ocid1.subnet..a",
        oci_base_image: "ocid1.image..a",
        pem: "/tmp/explicit-key.pem",
        quiet: true
      ]

      assert {:ok, %{subnet_id: "ocid1.subnet..a", image_id: "ocid1.image..a", key_name: "/tmp/explicit-key.pem"}} =
               CreateInstance.gather_infrastructure(opts)
    end
  end

  describe "terminate_all_runners/3 (D5: --force = replace)" do
    test "terminates every runner it is given" do
      runners = [
        %K6Runner{instance_id: "i-1"},
        %K6Runner{instance_id: "i-2"},
        %K6Runner{instance_id: "i-3"}
      ]

      terminate_fn = fn runner, _opts ->
        send(self(), {:terminated, runner.instance_id})
        :ok
      end

      assert CreateInstance.terminate_all_runners(runners, terminate_fn, []) === :ok
      assert_received {:terminated, "i-1"}
      assert_received {:terminated, "i-2"}
      assert_received {:terminated, "i-3"}
    end

    test "halts on the first termination failure and does not terminate the rest" do
      runners = [
        %K6Runner{instance_id: "i-1"},
        %K6Runner{instance_id: "i-2"},
        %K6Runner{instance_id: "i-3"}
      ]

      error = ErrorMessage.failed_dependency("could not terminate", %{instance_id: "i-2"})

      terminate_fn = fn
        %K6Runner{instance_id: "i-2"}, _opts -> {:error, error}
        runner, _opts -> send(self(), {:terminated, runner.instance_id}) && :ok
      end

      assert CreateInstance.terminate_all_runners(runners, terminate_fn, []) === {:error, error}
      assert_received {:terminated, "i-1"}
      refute_receive {:terminated, "i-3"}, 50
    end

    test "returns :ok for an empty runner list" do
      assert CreateInstance.terminate_all_runners([], fn _, _ -> :ok end, []) === :ok
    end
  end

  describe "do_wait_for_ssh/5 (D7: honest ssh wait)" do
    test "returns :ok as soon as the probe succeeds" do
      probe_fn = fn _ip -> true end
      sleep_fn = fn _ms -> send(self(), :slept) end

      assert CreateInstance.do_wait_for_ssh("i-123", "1.2.3.4", 3, probe_fn, sleep_fn) === :ok
      refute_receive :slept, 50
    end

    test "returns a failed_dependency error naming the instance and ip when retries are exhausted" do
      probe_fn = fn _ip -> false end
      sleep_fn = fn _ms -> :ok end

      assert {:error, %ErrorMessage{code: :failed_dependency, message: message}} =
               CreateInstance.do_wait_for_ssh("i-123", "1.2.3.4", 2, probe_fn, sleep_fn)

      assert message =~ "i-123"
      assert message =~ "1.2.3.4"
    end

    test "never reports success once retries are exhausted, even after prior failures" do
      probe_fn = fn _ip -> false end
      sleep_fn = fn _ms -> :ok end

      refute CreateInstance.do_wait_for_ssh("i-123", "1.2.3.4", 1, probe_fn, sleep_fn) === :ok
    end

    test "sleeps only between attempts — never after the final exhausting probe" do
      parent = self()
      probe_fn = fn _ip -> send(parent, :probed) && false end
      sleep_fn = fn _ms -> send(parent, :slept) end

      CreateInstance.do_wait_for_ssh("i-123", "1.2.3.4", 3, probe_fn, sleep_fn)

      assert_received :probed
      assert_received :slept
      assert_received :probed
      assert_received :slept
      assert_received :probed
      refute_received :slept
    end

    test "does not sleep at all when there is only one attempt" do
      parent = self()
      probe_fn = fn _ip -> send(parent, :probed) && false end
      sleep_fn = fn _ms -> send(parent, :slept) end

      CreateInstance.do_wait_for_ssh("i-123", "1.2.3.4", 1, probe_fn, sleep_fn)

      assert_received :probed
      refute_received :slept
    end
  end

  describe "do_wait_for_setup_complete/6 (D3: readiness gate)" do
    test "returns :ok as soon as the check succeeds" do
      check_fn = fn _ip, _pem_file -> true end
      sleep_fn = fn _ms -> send(self(), :slept) end

      assert CreateInstance.do_wait_for_setup_complete(
               "i-123", "1.2.3.4", "/tmp/key.pem", 3, check_fn, sleep_fn
             ) === :ok

      refute_receive :slept, 50
    end

    test "returns a failed_dependency error naming the instance and setup log when retries are exhausted" do
      check_fn = fn _ip, _pem_file -> false end
      sleep_fn = fn _ms -> :ok end

      assert {:error, %ErrorMessage{code: :failed_dependency, message: message}} =
               CreateInstance.do_wait_for_setup_complete(
                 "i-123", "1.2.3.4", "/tmp/key.pem", 2, check_fn, sleep_fn
               )

      assert message =~ "i-123"
      assert message =~ "/var/log/k6-setup.log"
    end

    test "sleeps only between attempts — never after the final exhausting check" do
      parent = self()
      check_fn = fn _ip, _pem_file -> send(parent, :checked) && false end
      sleep_fn = fn _ms -> send(parent, :slept) end

      CreateInstance.do_wait_for_setup_complete("i-123", "1.2.3.4", "/tmp/key.pem", 3, check_fn, sleep_fn)

      assert_received :checked
      assert_received :slept
      assert_received :checked
      assert_received :slept
      assert_received :checked
      refute_received :slept
    end

    test "does not sleep at all when there is only one attempt" do
      parent = self()
      check_fn = fn _ip, _pem_file -> send(parent, :checked) && false end
      sleep_fn = fn _ms -> send(parent, :slept) end

      CreateInstance.do_wait_for_setup_complete("i-123", "1.2.3.4", "/tmp/key.pem", 1, check_fn, sleep_fn)

      assert_received :checked
      refute_received :slept
    end
  end

  describe "reuse_existing_runner/2 (reuse-path readiness gate)" do
    test "returns the runner when the k6 setup check passes" do
      runner = %K6Runner{instance_id: "i-reuse-1", public_ip: "1.2.3.4", state: "running"}

      opts = [
        pem: "/tmp/fake.pem",
        quiet: true,
        check_fn: fn _ip, _pem_file -> true end,
        sleep_fn: fn _ms -> :ok end
      ]

      assert CreateInstance.reuse_existing_runner(runner, opts) === {:ok, runner}
    end

    test "runs the check through the injected check_fn, not blind trust" do
      runner = %K6Runner{instance_id: "i-reuse-2", public_ip: "1.2.3.4", state: "running"}
      parent = self()

      opts = [
        pem: "/tmp/fake.pem",
        quiet: true,
        check_fn: fn ip, pem_file ->
          send(parent, {:checked, ip, pem_file})
          true
        end,
        sleep_fn: fn _ms -> :ok end
      ]

      CreateInstance.reuse_existing_runner(runner, opts)

      assert_received {:checked, "1.2.3.4", "/tmp/fake.pem"}
    end

    test "returns an actionable error naming --force when k6 is not detected" do
      runner = %K6Runner{instance_id: "i-reuse-3", public_ip: "1.2.3.4", state: "running"}

      opts = [
        pem: "/tmp/fake.pem",
        quiet: true,
        check_fn: fn _ip, _pem_file -> false end,
        sleep_fn: fn _ms -> :ok end,
        setup_wait_retries: 1
      ]

      assert {:error, %ErrorMessage{code: :failed_dependency, message: message}} =
               CreateInstance.reuse_existing_runner(runner, opts)

      assert message =~ "i-reuse-3"
      assert message =~ "--force"
    end
  end

  describe "verify_created_runner/3 (post-create orphan guard, LT-FIX-A)" do
    test "returns the verified runner when AWS confirms it exists" do
      runner = %K6Runner{instance_id: "i-healthy"}

      assert {:ok, %K6Runner{instance_id: "i-healthy", state: "running"}} =
               CreateInstance.verify_created_runner(runner, [], FakeK6RunnerHealthy)
    end

    test "returns a loud failed_dependency error naming the leaked instance id when AWS still reports nothing" do
      runner = %K6Runner{instance_id: "i-orphan"}

      assert {:error, %ErrorMessage{code: :failed_dependency, message: message}} =
               CreateInstance.verify_created_runner(runner, [], FakeK6RunnerOrphaned)

      assert message =~ "i-orphan"
    end

    test "never returns {:ok, nil} — the create-path bug this guards against" do
      runner = %K6Runner{instance_id: "i-orphan"}

      refute CreateInstance.verify_created_runner(runner, [], FakeK6RunnerOrphaned) === {:ok, nil}
    end

    test "re-saves state so the orphaned instance remains findable/destroyable" do
      runner = %K6Runner{instance_id: "i-orphan"}

      CreateInstance.verify_created_runner(runner, [], FakeK6RunnerOrphaned)

      assert_received {:save_state_called, "i-orphan"}
    end
  end
end
