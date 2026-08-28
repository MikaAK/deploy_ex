defmodule Mix.Tasks.AnsibleMonitoringPlaybooksMimirTest do
  use ExUnit.Case, async: true

  # The three existing ansible/setup/*.yaml.eex playbooks gate their
  # grafana_alloy role line on `use_mimir` — asserted here via direct
  # EEx.eval_file against the priv/ source template and the pre-mimir
  # baseline fixtures (no side effects, mirrors the PrivRenderer-based
  # coverage in priv_renderer_mimir_test.exs at the template-source level).
  #
  # Baseline fixtures under test/support/fixtures/mimir/ were captured from the
  # pre-mimir tree (main @ e06649a) before any of this sprint's edits landed.

  @priv_setup_dir Path.expand("../../../priv/ansible/setup", __DIR__)
  @fixtures_dir Path.expand("../../support/fixtures/mimir", __DIR__)

  describe "existing monitoring setup playbooks gain grafana_alloy — nothing else changes" do
    for playbook <- ["grafana_ui", "loki_log_aggregator", "prometheus_db"] do
      test "#{playbook}.yaml.eex adds only the grafana_alloy role line when mimir is enabled" do
        playbook = unquote(playbook)
        baseline_lines = read_lines(Path.join(@fixtures_dir, "baseline_setup_#{playbook}.yaml"))
        rendered_lines = playbook |> render_setup_playbook(use_mimir: true) |> split_lines()

        added_lines = rendered_lines -- baseline_lines
        removed_lines = baseline_lines -- rendered_lines

        assert added_lines === ["    - grafana_alloy"]
        assert removed_lines === []
      end

      test "#{playbook}.yaml.eex is byte-identical to the pre-mimir baseline when mimir is disabled" do
        playbook = unquote(playbook)
        baseline = File.read!(Path.join(@fixtures_dir, "baseline_setup_#{playbook}.yaml"))
        rendered = render_setup_playbook(playbook, use_mimir: false)

        assert rendered === baseline
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

  defp render_setup_playbook(playbook, assigns) do
    @priv_setup_dir
    |> Path.join("#{playbook}.yaml.eex")
    |> EEx.eval_file(assigns: assigns)
  end

  defp split_lines(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&(&1 === ""))
  end

  defp read_lines(path) do
    path
    |> File.read!()
    |> split_lines()
  end
end
