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
  @privileged_modules ~w(systemd file template unarchive find uri apt package)
  @package_modules ~w(apt package)

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

  defp zip_unarchive_task?(task) do
    task |> get_in(["unarchive", "src"]) |> to_string() |> String.ends_with?(".zip")
  end

  defp package_args(task) do
    Enum.find_value(@package_modules, %{}, &Map.get(task, &1))
  end

  defp installs_zip_extractor?(task) do
    names = task |> package_args() |> Map.get("name", [])

    "unzip" in List.wrap(names)
  end

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

  defp render_ansible_template(template, vars) do
    Regex.replace(~r/{{\s*(\w+)\s*}}/, template, fn _whole, key -> Map.fetch!(vars, key) end)
  end

  defp evaluate_stat_condition(condition, stat_result) do
    cond do
      String.ends_with?(condition, ".stat.exists") -> Map.fetch!(stat_result, "exists")
      String.ends_with?(condition, ".stat.isdir") -> Map.fetch!(stat_result, "isdir")
    end
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

  # SECTION: D2-e — host tooling the download step depends on
  #
  # W2 fan-out defect (MEASURED, cfx_auth_web + cfx_user_portal_web, both nodes each):
  # `Failed to find handler for ".../alloy-linux-amd64....zip"`. Ansible's `unarchive`
  # shells out to `unzip` for a .zip src and has no built-in fallback. Alloy v1.9.0
  # publishes ONLY .zip assets for linux (20 release assets, 0 tar-family), so the
  # artifact cannot be switched — the role has to supply the extractor itself.
  #
  # The role worked everywhere it had been run as part of a full setup playbook only
  # because an earlier role in the same play installed unzip for its own download
  # (roles/awscli/tasks/main.yaml:14-17). That is an undeclared cross-role dependency;
  # running grafana_alloy on its own removes the provider and the role breaks.

  describe "grafana_alloy role — archive extractor" do
    test "a zip extractor is installed before the first .zip is unarchived" do
      indexed = tasks_main_yaml() |> flatten_tasks() |> Enum.with_index()

      zip_indices = for {task, index} <- indexed, zip_unarchive_task?(task), do: index
      extractor_indices = for {task, index} <- indexed, installs_zip_extractor?(task), do: index

      refute Enum.empty?(zip_indices)
      refute Enum.empty?(extractor_indices)

      assert Enum.min(extractor_indices) < Enum.min(zip_indices)
    end

    test "the zip extractor install is idempotent and resolves to become: true" do
      extractors =
        tasks_main_yaml()
        |> privileged_entries(false)
        |> Enum.filter(fn {entry, _become} -> installs_zip_extractor?(entry) end)

      assert [{extractor, become}] = extractors
      assert become === true
      assert extractor |> package_args() |> Map.get("state", "present") === "present"
    end
  end

  # SECTION: Deliverable 1 (alloy-journal-version) — a version bump must cause a
  # real redownload
  #
  # tasks/main.yaml stats `~/alloy-{{ alloy_architecture }}` — architecture only, no
  # version — then downloads `when: not alloy.stat.exists`. Every host that already
  # carries a binary at that fixed, architecture-only path (i.e. every host this role
  # has ever provisioned) skips the download on a version bump: the stat check cannot
  # tell "already has an older version" from "already has the target version". The
  # task NAME interpolates alloy_version, so it reads as version-aware in review while
  # the behaviour is not. This test proves the DOWNLOAD decision, not the path string —
  # a fix that merely embeds `{{ alloy_version }}` in the task name would leave this RED.

  describe "grafana_alloy role — version-aware download" do
    test "a version bump causes a redownload on a host that already carries an older, architecture-only-named binary" do
      tasks = flatten_tasks(tasks_main_yaml())

      stat_task = Enum.find(tasks, &(Map.get(&1, "register") === "alloy"))
      download_task = Enum.find(tasks, &Map.has_key?(&1, "unarchive"))

      refute is_nil(stat_task), "expected a stat task registering as `alloy`"
      refute is_nil(download_task), "expected an unarchive task downloading Alloy"

      stat_path_template = get_in(stat_task, ["stat", "path"])
      download_when = Map.fetch!(download_task, "when")

      assert download_when === "not alloy.stat.exists"

      architecture = "linux-amd64"

      # Every host this role has ever provisioned (pre-fix or not) has a raw binary
      # sitting at this fixed, architecture-only path — the pre-fix `stat.path`
      # verbatim. That is the realistic starting state for "already carries an older
      # binary", independent of however the fix decides to track installed versions.
      preexisting_host_paths = MapSet.new(["~/alloy-#{architecture}"])

      new_version_stat_path =
        render_ansible_template(stat_path_template, %{
          "alloy_architecture" => architecture,
          "alloy_version" => "v9.9.9"
        })

      new_version_already_present? = MapSet.member?(preexisting_host_paths, new_version_stat_path)
      download_runs_for_bumped_version? = not new_version_already_present?

      assert download_runs_for_bumped_version?,
        "expected bumping alloy_version to cause a fresh download on a host that " <>
          "already has an older, architecture-only-named Alloy binary, but the stat " <>
          "path (#{stat_path_template}) does not depend on alloy_version so the " <>
          "download was (incorrectly) skipped"
    end
  end

  # SECTION: Deliverable 2 (alloy-journal-version) — loud journal-directory precondition
  #
  # alloy_config.alloy.j2 hardcodes `path = "/var/log/journal"` for loki.source.journal.
  # On a host with volatile-only journald storage that directory does not exist, so
  # Alloy starts, passes /-/ready, and ships zero log lines — the readiness gate only
  # observes the process, not whether any log line was read. The fix asserts the
  # precondition loudly; it must NOT create the directory (that is a journald storage
  # policy decision outside this role's scope, already imposed as a manual AMI-bake
  # precondition). This test proves the assertion actually fails on a host with no
  # journal directory — not merely that a task mentioning "journal" exists.

  describe "grafana_alloy role — journal directory precondition" do
    test "asserts the persistent journal directory exists before Alloy is configured, and fails loudly when it does not" do
      tasks = flatten_tasks(tasks_main_yaml())

      stat_task = Enum.find(tasks, &(get_in(&1, ["stat", "path"]) === "/var/log/journal"))
      refute is_nil(stat_task), "expected a stat task checking /var/log/journal"

      registered_var = Map.fetch!(stat_task, "register")

      assert_task =
        Enum.find(tasks, fn task ->
          case get_in(task, ["assert", "that"]) do
            nil -> false
            that -> Enum.any?(List.wrap(that), &String.starts_with?(&1, registered_var))
          end
        end)

      refute is_nil(assert_task), "expected an assert task gating on the journal directory stat result"

      that_conditions = get_in(assert_task, ["assert", "that"])
      fail_msg = get_in(assert_task, ["assert", "fail_msg"]) || get_in(assert_task, ["assert", "msg"])

      refute is_nil(fail_msg), "expected the assertion to name the problem via fail_msg/msg"
      assert fail_msg =~ "journal"

      refute assert_task["ignore_errors"] === true
      refute assert_task["when"] === false

      no_journal_dir_passes? =
        Enum.all?(that_conditions, &evaluate_stat_condition(&1, %{"exists" => false, "isdir" => false}))

      has_journal_dir_passes? =
        Enum.all?(that_conditions, &evaluate_stat_condition(&1, %{"exists" => true, "isdir" => true}))

      refute no_journal_dir_passes?,
        "expected the journal precondition to fail loudly on a host with no /var/log/journal"

      assert has_journal_dir_passes?,
        "expected the journal precondition to pass on a host that already has /var/log/journal"

      indexed = Enum.with_index(tasks)
      {_stat, stat_index} = Enum.find(indexed, fn {task, _index} -> task === stat_task end)
      {_assert, assert_index} = Enum.find(indexed, fn {task, _index} -> task === assert_task end)

      {_config, config_index} =
        Enum.find(indexed, fn {task, _index} ->
          get_in(task, ["template", "src"]) === "alloy_config.alloy.j2"
        end)

      ready_index =
        indexed
        |> Enum.find(fn {task, _index} -> readiness_task?(task) end)
        |> elem(1)

      assert stat_index < assert_index
      assert assert_index < config_index
      assert assert_index < ready_index
    end
  end
end
