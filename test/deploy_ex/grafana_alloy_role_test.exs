defmodule DeployEx.GrafanaAlloyRoleTest do
  use ExUnit.Case, async: true

  # priv/ansible/roles/grafana_alloy is Ansible/Jinja content, not Elixir-rendered —
  # covered here via structural assertions on the parsed YAML task list (same
  # exemption/pattern as test/deploy_ex/mimir_role_test.exs).
  #
  # D2-a fixes two pre-existing defects (MEASURED by the lead, 2026-08-30):
  #   1. "Remove old promtail binary" used `shell: rm -f ...` with `args: warn: false`,
  #      which is a FATAL unsupported parameter on ansible-core 2.18.
  #   2. Promtail was stopped/removed FIRST, before Alloy was confirmed ready — a
  #      failure mid-role (or the fatal #1 defect) left a node with no log shipper.
  #
  # This suite pins: no `warn` arg anywhere, Alloy fully up + ready before ANY
  # promtail retirement task runs, the readiness task fails the play (not silently)
  # on timeout, template changes restart Alloy via a handler, and promtail retirement
  # never shells out.
  #
  # A prod canary then hit a third defect (MEASURED, cfx_cms): the `restart alloy`
  # handler ran unprivileged — `daemon-reload: Interactive authentication required` —
  # because the tasks block's `become: true` does not extend to handlers. The
  # privilege audit below pins that for every handler, not just this one.

  @priv_roles_dir Path.expand("../../priv/ansible/roles", __DIR__)
  @grafana_alloy_role_dir Path.join(@priv_roles_dir, "grafana_alloy")
  @privileged_modules ~w(systemd file template unarchive find uri)

  defp tasks_main_yaml do
    YamlElixir.read_from_file!(Path.join(@grafana_alloy_role_dir, "tasks/main.yaml"))
  end

  defp handlers_main_yaml do
    YamlElixir.read_from_file!(Path.join(@grafana_alloy_role_dir, "handlers/main.yaml"))
  end

  defp flatten_tasks(entries) do
    Enum.flat_map(entries, fn
      %{"block" => block} -> flatten_tasks(block)
      task -> [task]
    end)
  end

  defp readiness_task?(task), do: Map.has_key?(task, "uri")

  defp alloy_task?(task) do
    task
    |> task_name()
    |> String.contains?("alloy")
    |> Kernel.and(not readiness_task?(task))
  end

  defp promtail_task?(task) do
    task
    |> inspect()
    |> String.downcase()
    |> String.contains?("promtail")
  end

  defp task_name(task) do
    task |> Map.get("name", "") |> String.downcase()
  end

  defp privileged_module?(entry) do
    Enum.any?(@privileged_modules, &Map.has_key?(entry, &1))
  end

  # Ansible resolves `become` per entry, inheriting it from an enclosing block.
  # Handlers have no enclosing block, so they inherit nothing — that is the D2-a
  # defect class this audit encodes.
  defp privileged_entries(entries, inherited_become) do
    Enum.flat_map(entries, fn
      %{"block" => block} = entry ->
        privileged_entries(block, Map.get(entry, "become", inherited_become))

      entry ->
        if privileged_module?(entry) do
          [{entry, Map.get(entry, "become", inherited_become)}]
        else
          []
        end
    end)
  end

  # SECTION: DC1 — no task passes the removed `warn` argument

  describe "grafana_alloy role — no removed ansible-core 2.18 args" do
    test "no task, including nested block tasks, carries an args.warn key" do
      tasks = flatten_tasks(tasks_main_yaml())

      refute Enum.any?(tasks, &match?(%{"args" => %{"warn" => _}}, &1))
    end
  end

  # SECTION: DC2 — task ordering: alloy ready before any promtail retirement

  describe "grafana_alloy role — task ordering" do
    test "alloy is installed, configured and reported ready before any promtail task runs" do
      indexed = tasks_main_yaml() |> flatten_tasks() |> Enum.with_index()

      alloy_indices = for {task, index} <- indexed, alloy_task?(task), do: index
      promtail_indices = for {task, index} <- indexed, promtail_task?(task), do: index
      ready_indices = for {task, index} <- indexed, readiness_task?(task), do: index

      refute Enum.empty?(alloy_indices)
      refute Enum.empty?(promtail_indices)
      assert [ready_index] = ready_indices

      assert Enum.max(alloy_indices) < ready_index
      assert ready_index < Enum.min(promtail_indices)
    end
  end

  # SECTION: DC3 + DC6 — readiness gate

  describe "grafana_alloy role — readiness gate" do
    test "readiness task polls alloy's /-/ready with retries and fails the play on timeout" do
      indexed = tasks_main_yaml() |> flatten_tasks() |> Enum.with_index()

      {ready_task, ready_index} = Enum.find(indexed, fn {task, _index} -> readiness_task?(task) end)

      uri_args = Map.fetch!(ready_task, "uri")
      assert uri_args["url"] === "http://127.0.0.1:12345/-/ready"
      assert uri_args["status_code"] === 200
      assert ready_task["retries"] >= 12
      assert ready_task["delay"] >= 5
      assert Map.has_key?(ready_task, "until")
      assert is_integer(uri_args["timeout"])
      assert uri_args["timeout"] <= 10

      refute Map.has_key?(ready_task, "ignore_errors")
      refute ready_task["failed_when"] === false

      {previous_task, _index} = Enum.at(indexed, ready_index - 1)
      assert previous_task["meta"] === "flush_handlers"
    end
  end

  # SECTION: DC4 — handler wiring

  describe "grafana_alloy role — handlers" do
    test "handlers/main.yaml defines a restart alloy handler that runs with become" do
      restart_handler = Enum.find(handlers_main_yaml(), &(&1["name"] === "restart alloy"))
      refute is_nil(restart_handler)

      systemd_args = Map.fetch!(restart_handler, "systemd")
      assert systemd_args["name"] === "alloy"
      assert systemd_args["state"] === "restarted"
      assert systemd_args["daemon_reload"] === true

      assert restart_handler["become"] === true
    end

    test "every handler carries its own become because block-level become does not reach handlers" do
      handlers = handlers_main_yaml()

      refute Enum.empty?(handlers)

      unprivileged_handlers =
        for handler <- handlers, handler["become"] !== true, do: handler["name"]

      assert unprivileged_handlers === []
    end

    test "config and unit template changes notify the restart alloy handler" do
      tasks = flatten_tasks(tasks_main_yaml())

      config_task = Enum.find(tasks, &(get_in(&1, ["template", "src"]) === "alloy_config.alloy.j2"))
      service_task = Enum.find(tasks, &(get_in(&1, ["template", "src"]) === "alloy_systemd.service.j2"))

      refute is_nil(config_task)
      refute is_nil(service_task)
      assert config_task["notify"] === "restart alloy"
      assert service_task["notify"] === "restart alloy"
    end
  end

  # SECTION: DC5 — promtail retirement, no shell/command

  describe "grafana_alloy role — promtail retirement" do
    test "promtail retirement uses no shell/command module" do
      promtail_tasks = tasks_main_yaml() |> flatten_tasks() |> Enum.filter(&promtail_task?/1)

      refute Enum.empty?(promtail_tasks)
      refute Enum.any?(promtail_tasks, &Map.has_key?(&1, "shell"))
      refute Enum.any?(promtail_tasks, &Map.has_key?(&1, "command"))
    end
  end

  # SECTION: D2-a — privilege audit across the whole role (tasks block + handlers)

  describe "grafana_alloy role — privilege audit" do
    test "the role's task block carries block-level become" do
      block_entry = Enum.find(tasks_main_yaml(), &Map.has_key?(&1, "block"))

      refute is_nil(block_entry)
      assert block_entry["become"] === true
    end

    test "every task and handler using a privileged module resolves to become: true" do
      entries =
        privileged_entries(tasks_main_yaml(), false) ++
          privileged_entries(handlers_main_yaml(), false)

      refute Enum.empty?(entries)

      unprivileged_names =
        for {entry, become} <- entries, become !== true, do: task_name(entry)

      assert unprivileged_names === []
    end
  end
end
