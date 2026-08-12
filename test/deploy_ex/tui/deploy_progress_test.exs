defmodule DeployEx.TUI.DeployProgressTest do
  use ExUnit.Case, async: true

  alias DeployEx.TUI.DeployProgress

  describe "run/3 failure propagation" do
    # Task.async_stream wraps every completed task as {:ok, result}, so a run_fn returning
    # {:error, _} reaches the reducer as {:ok, {:error, _}} — which matches its SUCCESS clause.
    # Without unwrapping, a failed ansible play is aggregated as a successful record,
    # ansible.setup/ansible.deploy skip their Mix.raise, and the task exits 0. In CI that is a
    # green deploy that never deployed. MEASURED against a live node: a play with failed=1
    # exited 0.
    test "a run_fn error makes run/3 report an error, not a successful record" do
      run_fn = fn _playbook, _callback ->
        {:error, ErrorMessage.internal_server_error("command failed", %{code: 2})}
      end

      assert {:error, [%ErrorMessage{code: :internal_server_error}]} =
               DeployProgress.run(["setup/app.yaml"], run_fn)
    end

    test "one failure among several still reports an error" do
      run_fn = fn
        "setup/bad.yaml", _callback -> {:error, ErrorMessage.internal_server_error("boom")}
        _playbook, _callback -> :ok
      end

      assert {:error, errors} =
               DeployProgress.run(["setup/ok.yaml", "setup/bad.yaml", "setup/ok2.yaml"], run_fn)

      assert length(errors) === 1
    end

    test "all succeeding still reports ok" do
      assert {:ok, _} = DeployProgress.run(["setup/a.yaml"], fn _playbook, _callback -> :ok end)
    end
  end

  describe "action_labels/1" do
    test "defaults to deploy wording" do
      assert DeployProgress.action_labels([]) === %{gerund: "Deploying", noun: "Deploy"}
    end

    test "honors action_gerund and action_noun overrides" do
      labels = DeployProgress.action_labels(action_gerund: "Setting Up", action_noun: "Setup")

      assert labels === %{gerund: "Setting Up", noun: "Setup"}
    end
  end
end
