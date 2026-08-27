defmodule Mix.Tasks.DeployEx.LoadTestAdversarialTest do
  @moduledoc """
  Adversarial contract probe for the `mix deploy_ex.load_test.*` task family —
  written against docs/superpowers/plans/lt-fix/spec.md (D3-D11) and
  sprint-2-provision.md / sprint-3-client.md ONLY. This file was NOT written
  by reading create_instance.ex, list.ex, upload.ex, or exec.ex; every
  assertion pins a promise made in the contract, not a detail of the
  implementation. Where an internal collaborator shape (e.g. the exact
  functions a `k6_runner_impl` module must expose) is not pinned by the
  contract, this file stubs the plausible surface and treats an
  UndefinedFunctionError/BadArityError as a legitimate finding, not a bug in
  the test.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DeployEx.K6Runner
  alias Mix.Tasks.DeployEx.LoadTest.CreateInstance
  alias Mix.Tasks.DeployEx.LoadTest.Exec
  alias Mix.Tasks.DeployEx.LoadTest.List
  alias Mix.Tasks.DeployEx.LoadTest.Upload

  defmodule FakeK6RunnerImpl do
    @moduledoc false

    def configure(response), do: Process.put({__MODULE__, :response}, response)

    def fetch_all_runners(opts \\ []), do: respond(:fetch_all_runners, [opts])
    def verify_instance_exists(instance_id), do: respond(:verify_instance_exists, [instance_id])
    def fetch_state(instance_id, opts \\ []), do: respond(:fetch_state, [instance_id, opts])

    defp respond(fun_name, args) do
      send(self(), {:k6_runner_impl_called, fun_name, args})

      case Process.get({__MODULE__, :response}) do
        nil -> raise "FakeK6RunnerImpl response not configured for #{fun_name}/#{length(args)}"
        response -> response
      end
    end
  end

  setup do
    start_event_log()
    :ok
  end

  # SECTION do_wait_for_ssh/5 — honest waits (D7)

  describe "CreateInstance.do_wait_for_ssh/5 — honest waits (D7)" do
    test "returns an error naming the instance when retries exhaust, never :ok" do
      probe_fn = fn _ip ->
        log_event(:probe)
        false
      end

      sleep_fn = fn _duration_ms -> log_event(:sleep) end

      result =
        CreateInstance.do_wait_for_ssh("i-0abc123exhaust", "10.0.0.5", 3, probe_fn, sleep_fn)

      refute result === :ok
      assert {:error, %ErrorMessage{} = error} = result
      assert error.message =~ "i-0abc123exhaust"
    end

    test "probes exactly `retries` times before giving up" do
      probe_fn = fn _ip ->
        log_event(:probe)
        false
      end

      sleep_fn = fn _duration_ms -> log_event(:sleep) end

      CreateInstance.do_wait_for_ssh("i-probe-count", "10.0.0.5", 4, probe_fn, sleep_fn)

      assert Enum.count(events(), &(&1 === :probe)) === 4
    end

    test "sleeps between retries, never before the first probe" do
      probe_fn = fn _ip ->
        log_event(:probe)
        false
      end

      sleep_fn = fn _duration_ms -> log_event(:sleep) end

      CreateInstance.do_wait_for_ssh("i-order", "10.0.0.5", 3, probe_fn, sleep_fn)

      recorded = events()
      assert hd(recorded) === :probe
      assert Enum.count(recorded, &(&1 === :sleep)) === 2
    end

    test "zero-retry edge: fails immediately without probing or sleeping" do
      probe_fn = fn _ip ->
        log_event(:probe)
        false
      end

      sleep_fn = fn _duration_ms -> log_event(:sleep) end

      result = CreateInstance.do_wait_for_ssh("i-zero", "10.0.0.5", 0, probe_fn, sleep_fn)

      assert {:error, %ErrorMessage{}} = result
      assert events() === []
    end
  end

  # SECTION do_wait_for_setup_complete/6 — honest waits (D3)

  describe "CreateInstance.do_wait_for_setup_complete/6 — honest waits (D3)" do
    test "returns an error naming the instance when retries exhaust, never :ok" do
      check_fn = fn _ip, _pem_file ->
        log_event(:check)
        false
      end

      sleep_fn = fn _duration_ms -> log_event(:sleep) end

      result =
        CreateInstance.do_wait_for_setup_complete(
          "i-setup-exhaust",
          "10.0.0.6",
          "/tmp/fake.pem",
          3,
          check_fn,
          sleep_fn
        )

      refute result === :ok
      assert {:error, %ErrorMessage{} = error} = result
      assert error.message =~ "i-setup-exhaust"
    end

    test "checks exactly `retries` times before giving up" do
      check_fn = fn _ip, _pem_file ->
        log_event(:check)
        false
      end

      sleep_fn = fn _duration_ms -> log_event(:sleep) end

      CreateInstance.do_wait_for_setup_complete(
        "i-setup-count",
        "10.0.0.6",
        "/tmp/fake.pem",
        3,
        check_fn,
        sleep_fn
      )

      assert Enum.count(events(), &(&1 === :check)) === 3
    end

    test "sleeps between checks, never before the first" do
      check_fn = fn _ip, _pem_file ->
        log_event(:check)
        false
      end

      sleep_fn = fn _duration_ms -> log_event(:sleep) end

      CreateInstance.do_wait_for_setup_complete(
        "i-setup-order",
        "10.0.0.6",
        "/tmp/fake.pem",
        3,
        check_fn,
        sleep_fn
      )

      recorded = events()
      assert hd(recorded) === :check
      assert Enum.count(recorded, &(&1 === :sleep)) === 2
    end

    test "zero-retry edge: fails immediately without checking or sleeping" do
      check_fn = fn _ip, _pem_file ->
        log_event(:check)
        false
      end

      sleep_fn = fn _duration_ms -> log_event(:sleep) end

      result =
        CreateInstance.do_wait_for_setup_complete(
          "i-setup-zero",
          "10.0.0.6",
          "/tmp/fake.pem",
          0,
          check_fn,
          sleep_fn
        )

      assert {:error, %ErrorMessage{}} = result
      assert events() === []
    end
  end

  # SECTION terminate_all_runners/3 — force-replace semantics (D5)

  describe "CreateInstance.terminate_all_runners/3 — force-replace semantics (D5)" do
    test "returns :ok for an empty list without calling terminate_fn" do
      terminate_fn = fn runner, _opts ->
        log_event({:terminate, runner})
        :ok
      end

      assert CreateInstance.terminate_all_runners([], terminate_fn, []) === :ok
      assert events() === []
    end

    test "terminates every runner exactly once when all succeed" do
      terminate_fn = fn runner, _opts ->
        log_event({:terminate, runner})
        :ok
      end

      runners = ["i-aaa", "i-bbb", "i-ccc"]

      assert CreateInstance.terminate_all_runners(runners, terminate_fn, []) === :ok

      terminated = Enum.map(events(), fn {:terminate, runner} -> runner end)
      assert terminated === runners
      assert Enum.uniq(terminated) === terminated
    end

    test "halts on the first termination error and does not terminate later runners" do
      terminate_fn = fn
        "i-aaa", _opts ->
          log_event({:terminate, "i-aaa"})
          {:error, ErrorMessage.internal_server_error("boom")}

        runner, _opts ->
          log_event({:terminate, runner})
          :ok
      end

      runners = ["i-aaa", "i-bbb", "i-ccc"]

      result = CreateInstance.terminate_all_runners(runners, terminate_fn, [])

      assert {:error, %ErrorMessage{}} = result
      terminated = Enum.map(events(), fn {:terminate, runner} -> runner end)
      assert terminated === ["i-aaa"]
    end
  end

  # SECTION list --json (D4)

  describe "List.output_runners/2 — list --json (D4)" do
    test "json: true emits output that decodes as a JSON list containing every runner" do
      runner = K6Runner.from_json(%{"instance_id" => "i-json-1", "public_ip" => "1.2.3.4"})

      output = capture_io(fn -> List.output_runners([runner], json: true) end)

      assert {:ok, decoded} = Jason.decode(output)
      assert is_list(decoded)
      assert length(decoded) === 1
    end

    test "no json flag renders a table, not machine-parseable JSON" do
      runner = K6Runner.from_json(%{"instance_id" => "i-table-1", "public_ip" => "1.2.3.4"})

      output = capture_io(fn -> List.output_runners([runner], []) end)

      assert match?({:error, _reason}, Jason.decode(output))
    end

    test "json output round-trips every struct field, including nil ones" do
      runner = K6Runner.from_json(%{"instance_id" => "i-roundtrip-1"})

      output = capture_io(fn -> List.output_runners([runner], json: true) end)
      {:ok, [decoded_runner]} = Jason.decode(output)

      expected_fields = runner |> Map.from_struct() |> Map.keys() |> Enum.map(&to_string/1)

      Enum.each(expected_fields, fn field ->
        assert Map.has_key?(decoded_runner, field),
               "expected JSON output to include field #{inspect(field)}, got keys: " <>
                 "#{inspect(Map.keys(decoded_runner))}"
      end)
    end
  end

  # SECTION nil-runner handling (D6)

  describe "Upload.resolve_runner/2 — nil-runner handling (D6)" do
    test "default path: {:ok, nil} resolves to a not_found error naming create_instance" do
      FakeK6RunnerImpl.configure({:ok, nil})

      result = Upload.resolve_runner([], FakeK6RunnerImpl)

      assert_received {:k6_runner_impl_called, _fun_name, _args},
                       "resolve_runner never called the injected k6_runner_impl seam"

      assert {:error, %ErrorMessage{code: :not_found} = error} = result
      assert error.message =~ "create_instance"
    end

    test "--instance-id path: {:ok, nil} resolves to a not_found error naming create_instance" do
      FakeK6RunnerImpl.configure({:ok, nil})

      result = Upload.resolve_runner([instance_id: "i-terminated"], FakeK6RunnerImpl)

      assert_received {:k6_runner_impl_called, _fun_name, _args},
                       "resolve_runner never called the injected k6_runner_impl seam"

      assert {:error, %ErrorMessage{code: :not_found} = error} = result
      assert error.message =~ "create_instance"
    end

    test "passes a fetch error through unchanged" do
      error = ErrorMessage.service_unavailable("aws is down")
      FakeK6RunnerImpl.configure({:error, error})

      assert Upload.resolve_runner([], FakeK6RunnerImpl) === {:error, error}
    end
  end

  describe "Exec.resolve_runner/2 — nil-runner handling (D6)" do
    test "default path: {:ok, nil} resolves to a not_found error naming create_instance" do
      FakeK6RunnerImpl.configure({:ok, nil})

      result = Exec.resolve_runner([], FakeK6RunnerImpl)

      assert_received {:k6_runner_impl_called, _fun_name, _args},
                       "resolve_runner never called the injected k6_runner_impl seam"

      assert {:error, %ErrorMessage{code: :not_found} = error} = result
      assert error.message =~ "create_instance"
    end

    test "--instance-id path: {:ok, nil} resolves to a not_found error naming create_instance" do
      FakeK6RunnerImpl.configure({:ok, nil})

      result = Exec.resolve_runner([instance_id: "i-terminated"], FakeK6RunnerImpl)

      assert_received {:k6_runner_impl_called, _fun_name, _args},
                       "resolve_runner never called the injected k6_runner_impl seam"

      assert {:error, %ErrorMessage{code: :not_found} = error} = result
      assert error.message =~ "create_instance"
    end

    test "passes a fetch error through unchanged" do
      error = ErrorMessage.service_unavailable("aws is down")
      FakeK6RunnerImpl.configure({:error, error})

      assert Exec.resolve_runner([], FakeK6RunnerImpl) === {:error, error}
    end
  end

  # SECTION prometheus URL precedence (D8)

  describe "Exec.resolve_prometheus_url/2 — precedence (D8)" do
    test "an explicit --prometheus-url flag wins and discovery is never invoked" do
      discover_fn = fn ->
        flunk("discover_fn must not be called when --prometheus-url is given")
      end

      result = Exec.resolve_prometheus_url([prometheus_url: "http://5.5.5.5:9090"], discover_fn)

      assert {:ok, "http://5.5.5.5:9090"} = result
    end

    test "discovery returning a private IP formats http://ip:9090" do
      discover_fn = fn -> {:ok, "10.0.101.171"} end

      assert {:ok, "http://10.0.101.171:9090"} =
               Exec.resolve_prometheus_url([], discover_fn)
    end

    test "no flag and no discovered node resolves to nil" do
      discover_fn = fn -> {:ok, nil} end

      assert {:ok, nil} = Exec.resolve_prometheus_url([], discover_fn)
    end
  end

  # SECTION k6 command string boundaries (D8/D11)

  describe "Exec.build_k6_command/3 — command string boundaries (D8/D11)" do
    test "no prometheus URL and no target URL: no -o flag, no env vars for either" do
      command = Exec.build_k6_command("script.js", nil, nil)

      refute command =~ "-o experimental-prometheus-rw"
      refute command =~ "K6_PROMETHEUS_RW_SERVER_URL"
      refute command =~ "TARGET_URL"
      assert command =~ "script.js"
    end

    test "prometheus URL given: adds -o flag and env var, no double spaces or dangling assignment" do
      command = Exec.build_k6_command("script.js", "http://10.0.101.171:9090", nil)

      assert command =~ "-o experimental-prometheus-rw"
      assert command =~ "K6_PROMETHEUS_RW_SERVER_URL=http://10.0.101.171:9090"
      refute command =~ "TARGET_URL"
      refute command =~ "  "
      refute Regex.match?(~r/\b[A-Z_]+=(?=\s|$)/, command)
    end

    test "target URL given without prometheus: TARGET_URL present, no prometheus flag/env" do
      command = Exec.build_k6_command("script.js", nil, "http://backend/health")

      assert command =~ "TARGET_URL=http://backend/health"
      refute command =~ "-o experimental-prometheus-rw"
      refute command =~ "K6_PROMETHEUS_RW_SERVER_URL"
      refute command =~ "  "
    end

    test "both URLs given: both env vars present with clean boundaries" do
      command =
        Exec.build_k6_command("script.js", "http://10.0.101.171:9090", "http://backend/health")

      assert command =~ "TARGET_URL=http://backend/health"
      assert command =~ "K6_PROMETHEUS_RW_SERVER_URL=http://10.0.101.171:9090"
      assert command =~ "-o experimental-prometheus-rw"
      refute command =~ "  "
      refute Regex.match?(~r/\b[A-Z_]+=(?=\s|$)/, command)
    end
  end

  defp start_event_log, do: Process.put(:adv_test_events, [])

  defp log_event(event) do
    Process.put(:adv_test_events, [event | Process.get(:adv_test_events, [])])
  end

  defp events, do: Enum.reverse(Process.get(:adv_test_events, []))
end
