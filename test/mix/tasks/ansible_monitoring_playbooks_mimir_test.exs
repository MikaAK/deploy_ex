defmodule Mix.Tasks.AnsibleMonitoringPlaybooksMimirTest do
  use ExUnit.Case, async: true

  # Static ansible/setup/*.yaml playbooks are copied byte-for-byte (no EEx rendering) —
  # asserted directly against the priv/ source and pre-mimir baseline fixtures.

  @priv_setup_dir Path.expand("../../../priv/ansible/setup", __DIR__)
  @fixtures_dir Path.expand("../../support/fixtures/mimir", __DIR__)

  describe "existing monitoring setup playbooks gain grafana_alloy — nothing else changes" do
    for playbook <- ["grafana_ui", "loki_log_aggregator", "prometheus_db"] do
      test "#{playbook}.yaml adds only the grafana_alloy role line" do
        playbook = unquote(playbook)
        baseline_lines = read_lines(Path.join(@fixtures_dir, "baseline_setup_#{playbook}.yaml"))
        current_lines = read_lines(Path.join(@priv_setup_dir, "#{playbook}.yaml"))

        added_lines = current_lines -- baseline_lines
        removed_lines = baseline_lines -- current_lines

        assert added_lines === ["    - grafana_alloy"]
        assert removed_lines === []
      end
    end
  end

  describe "new mimir_db.yaml setup playbook" do
    test "targets monitoring_mimir_db with the expected role list" do
      content = File.read!(Path.join(@priv_setup_dir, "mimir_db.yaml"))

      assert content =~ "hosts: monitoring_mimir_db"
      assert content =~ "- pip3"
      assert content =~ "- awscli"
      assert content =~ "- prometheus_exporter"
      assert content =~ "- grafana_alloy"
      assert content =~ "- mimir_db"
      assert content =~ "- ipv6"
    end
  end

  defp read_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(&1 === ""))
  end
end
