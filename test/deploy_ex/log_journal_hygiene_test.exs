defmodule DeployEx.LogJournalHygieneTest do
  use ExUnit.Case, async: true

  # docs/superpowers/plans/d5-backlog/infra-hygiene-lane.md — MEASURED: four
  # monitoring/infra playbooks (prometheus_db, mimir_db, sentry, grafana_ui)
  # never include log_cleanup at all, and SystemMaxUse appears nowhere in the
  # repo — the only journal control shipped is a WEEKLY --vacuum-time=5m,
  # unbounded between runs, which is how a prod journal reached 784 MB.
  # Adding log_cleanup alone would fix the thing that was not broken; the cap
  # is the load-bearing part.
  #
  # The journald cap lives INSIDE the log_cleanup role (not a new role):
  # every playbook that needs the cap already carries (or, after this
  # commit, gains) log_cleanup, so putting the cap there means it reaches
  # every class the moment log_cleanup is referenced, with no second role to
  # keep in sync across seven playbooks — a second role would reintroduce
  # exactly the kind of "playbook forgot to include it" gap this lane closes.
  #
  # Raw content/order assertions, same exemption/pattern as
  # test/deploy_ex/mimir_role_test.exs (EEx-conditional playbooks aren't
  # valid YAML, so no YamlElixir parse here).

  @priv_ansible_dir Path.expand("../../priv/ansible", __DIR__)
  @setup_dir Path.join(@priv_ansible_dir, "setup")
  @log_cleanup_role_dir Path.join(@priv_ansible_dir, "roles/log_cleanup")

  @playbooks_missing_log_cleanup [
    {"prometheus_db.yaml.eex", Path.join(@setup_dir, "prometheus_db.yaml.eex")},
    {"mimir_db.yaml", Path.join(@setup_dir, "mimir_db.yaml")},
    {"sentry.yaml", Path.join(@setup_dir, "sentry.yaml")},
    {"grafana_ui.yaml.eex", Path.join(@setup_dir, "grafana_ui.yaml.eex")}
  ]

  defp byte_offset(content, substring) do
    {offset, _length} = :binary.match(content, substring)
    offset
  end

  # SECTION: log_cleanup added to the four classes that lack it, at the same
  # list position redis.yaml and loki_log_aggregator.yaml.eex already use
  # (after awscli, before prometheus_exporter).

  describe "monitoring/infra playbooks — log_cleanup coverage" do
    for {name, path} <- @playbooks_missing_log_cleanup do
      test "#{name} includes log_cleanup between awscli and prometheus_exporter" do
        content = File.read!(unquote(path))

        assert content =~ "- log_cleanup"

        awscli_offset = byte_offset(content, "- awscli")
        log_cleanup_offset = byte_offset(content, "- log_cleanup")
        prometheus_exporter_offset = byte_offset(content, "- prometheus_exporter")

        assert awscli_offset < log_cleanup_offset
        assert log_cleanup_offset < prometheus_exporter_offset
      end
    end
  end

  # SECTION: journald cap — the load-bearing part; log_cleanup alone only
  # fixes classes that were never broken.

  describe "log_cleanup role — journald cap" do
    test "creates the journald.conf.d directory before copying the drop-in" do
      content = File.read!(Path.join(@log_cleanup_role_dir, "tasks/main.yml"))

      assert content =~ "state: directory"
      assert content =~ "/etc/systemd/journald.conf.d"

      dir_offset = byte_offset(content, "/etc/systemd/journald.conf.d\n")
      copy_offset = byte_offset(content, "journald.conf.d/10-limits.conf")

      assert dir_offset < copy_offset
    end

    test "restarts systemd-journald after copying the drop-in" do
      content = File.read!(Path.join(@log_cleanup_role_dir, "tasks/main.yml"))

      copy_offset = byte_offset(content, "journald.conf.d/10-limits.conf")
      restart_offset = byte_offset(content, "name: systemd-journald")

      assert content =~ "systemd:"
      assert content =~ "state: restarted"
      assert copy_offset < restart_offset
    end

    test "the drop-in file sets a non-empty SystemMaxUse" do
      content = File.read!(Path.join(@log_cleanup_role_dir, "files/journald-limits.conf"))

      assert [_match, value] = Regex.run(~r/SystemMaxUse=(\S+)/, content)
      refute value === ""
    end
  end

  # SECTION: vacuum window — a time-based vacuum alone can never bound disk
  # (a chatty day fills the volume inside any window); the cap does the
  # bounding, the vacuum only trims stale history. 7d because Loki retains
  # 30d and is the system of record, and swap is untouched — a recorded
  # decision, not this lane's concern.

  describe "log_cleanup role — vacuum window" do
    test "clear_drive_space vacuums 7d instead of the unbounded-between-runs 5m" do
      content = File.read!(Path.join(@log_cleanup_role_dir, "files/clear_drive_space"))

      refute content =~ "--vacuum-time=5m"
      assert content =~ "--vacuum-time=7d"
    end

    test "clear_drive_space carries no swap changes (recorded decision, out of scope)" do
      content = File.read!(Path.join(@log_cleanup_role_dir, "files/clear_drive_space"))

      refute content =~ ~r/swap/i
    end
  end
end
