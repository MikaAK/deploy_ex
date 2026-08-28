defmodule Mix.Tasks.DeployEx.LoadTest.DestroyInstanceTest do
  use ExUnit.Case, async: true

  alias DeployEx.K6Runner
  alias Mix.Tasks.DeployEx.LoadTest.DestroyInstance

  describe "destroy_runners/3 + failed_runners/1 (destroy honesty)" do
    test "counts real successes — every runner terminated returns no failures" do
      runners = [
        %K6Runner{instance_id: "i-1"},
        %K6Runner{instance_id: "i-2"},
        %K6Runner{instance_id: "i-3"}
      ]

      terminate_fn = fn _runner, _opts -> :ok end

      results = DestroyInstance.destroy_runners(runners, terminate_fn, quiet: true)

      assert length(results) === 3
      assert DestroyInstance.failed_runners(results) === []
    end

    test "failed_runners returns exactly the runners whose termination errored" do
      runners = [
        %K6Runner{instance_id: "i-1"},
        %K6Runner{instance_id: "i-2"},
        %K6Runner{instance_id: "i-3"}
      ]

      error = ErrorMessage.internal_server_error("boom")

      terminate_fn = fn
        %K6Runner{instance_id: "i-2"}, _opts -> {:error, error}
        _runner, _opts -> :ok
      end

      results = DestroyInstance.destroy_runners(runners, terminate_fn, quiet: true)
      failed = DestroyInstance.failed_runners(results)

      assert Enum.map(failed, & &1.instance_id) === ["i-2"]
    end

    test "failed_runners returns every failing runner, not just the first" do
      runners = [
        %K6Runner{instance_id: "i-1"},
        %K6Runner{instance_id: "i-2"},
        %K6Runner{instance_id: "i-3"}
      ]

      error = ErrorMessage.internal_server_error("boom")
      terminate_fn = fn _runner, _opts -> {:error, error} end

      results = DestroyInstance.destroy_runners(runners, terminate_fn, quiet: true)
      failed = DestroyInstance.failed_runners(results)

      assert Enum.map(failed, & &1.instance_id) === ["i-1", "i-2", "i-3"]
    end

    test "attempts every runner even after an earlier one fails (unlike terminate_all_runners)" do
      runners = [
        %K6Runner{instance_id: "i-1"},
        %K6Runner{instance_id: "i-2"},
        %K6Runner{instance_id: "i-3"}
      ]

      error = ErrorMessage.internal_server_error("boom")

      terminate_fn = fn
        %K6Runner{instance_id: "i-1"}, _opts -> {:error, error}
        runner, _opts -> send(self(), {:terminated, runner.instance_id}) && :ok
      end

      DestroyInstance.destroy_runners(runners, terminate_fn, quiet: true)

      assert_received {:terminated, "i-2"}
      assert_received {:terminated, "i-3"}
    end
  end

  describe "destroy_failure_message/2" do
    test "names the leftover instance ids and the success/total count" do
      runners = [
        %K6Runner{instance_id: "i-1"},
        %K6Runner{instance_id: "i-2"},
        %K6Runner{instance_id: "i-3"}
      ]

      failed = [%K6Runner{instance_id: "i-2"}]

      message = DestroyInstance.destroy_failure_message(runners, failed)

      assert message =~ "i-2"
      assert message =~ "2/3"
      refute message =~ "i-1"
      refute message =~ "i-3"
    end
  end

  describe "ambiguous_scope_error/2 (--all semantics)" do
    test "allows a single runner with neither --instance-id nor --all" do
      runners = [%K6Runner{instance_id: "i-1"}]

      assert DestroyInstance.ambiguous_scope_error(runners, []) === :ok
    end

    test "allows multiple runners when --all is passed" do
      runners = [%K6Runner{instance_id: "i-1"}, %K6Runner{instance_id: "i-2"}]

      assert DestroyInstance.ambiguous_scope_error(runners, all: true) === :ok
    end

    test "allows multiple runners when --instance-id is passed" do
      runners = [%K6Runner{instance_id: "i-1"}, %K6Runner{instance_id: "i-2"}]

      assert DestroyInstance.ambiguous_scope_error(runners, instance_id: "i-1") === :ok
    end

    test "allows an empty runner list" do
      assert DestroyInstance.ambiguous_scope_error([], []) === :ok
    end

    test "refuses multiple runners with neither flag, naming every runner id" do
      runners = [
        %K6Runner{instance_id: "i-1"},
        %K6Runner{instance_id: "i-2"},
        %K6Runner{instance_id: "i-3"}
      ]

      assert {:error, %ErrorMessage{code: :bad_request, message: message}} =
               DestroyInstance.ambiguous_scope_error(runners, [])

      assert message =~ "i-1"
      assert message =~ "i-2"
      assert message =~ "i-3"
      assert message =~ "--all"
    end
  end
end
