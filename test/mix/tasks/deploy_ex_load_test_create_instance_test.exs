defmodule Mix.Tasks.DeployEx.LoadTest.CreateInstanceTest do
  use ExUnit.Case, async: true

  alias DeployEx.K6Runner
  alias Mix.Tasks.DeployEx.LoadTest.CreateInstance

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
  end
end
