defmodule DeployEx.MimirRoleTest do
  use ExUnit.Case, async: true

  # priv/ansible/roles/mimir_db and its downstream j2/yaml templates are Ansible/Jinja
  # content, not Elixir-rendered — covered here via raw structural/content assertions
  # (template exemption per the sprint contract; deeper render-diff done manually with
  # the local ansible-bundled jinja2 as evidence, not as a committed `mix test` dependency).

  @priv_roles_dir Path.expand("../../priv/ansible/roles", __DIR__)
  @mimir_role_dir Path.join(@priv_roles_dir, "mimir_db")
  @prometheus_role_dir Path.join(@priv_roles_dir, "prometheus_db")
  @fixtures_dir Path.expand("../support/fixtures/mimir", __DIR__)

  # SECTION: prometheus_db role untouched (FORBIDDEN list)

  describe "prometheus_db role files — untouched" do
    for relative_path <- [
          "tasks/main.yaml",
          "templates/prometheus-rules.yaml.j2",
          "templates/prometheus.service.j2",
          "templates/prometheus.yaml.j2"
        ] do
      test "#{relative_path} is byte-identical to the pre-mimir baseline" do
        relative_path = unquote(relative_path)

        baseline = File.read!(Path.join([@fixtures_dir, "prometheus_db_role", relative_path]))
        current = File.read!(Path.join(@prometheus_role_dir, relative_path))

        assert current === baseline
      end
    end
  end

  # SECTION: mimir_db role — shared rules invariant (single source, no duplication)

  describe "mimir_db role — shared alert rules (single source)" do
    test "tasks/main.yaml references prometheus_db's rules template via role_path" do
      content = File.read!(Path.join(@mimir_role_dir, "tasks/main.yaml"))

      assert content =~ "{{ role_path }}/../prometheus_db/templates/prometheus-rules.yaml.j2"
    end

    test "does not keep its own copy of prometheus-rules.yaml.j2 (no duplicated rule content)" do
      duplicate_path = Path.join(@mimir_role_dir, "templates/prometheus-rules.yaml.j2")

      refute File.exists?(duplicate_path)
    end
  end

  # SECTION: mimir_db role — structure

  describe "mimir_db role — task structure" do
    test "downloads the pinned Mimir binary, installs config + systemd unit, restarts on change" do
      content = File.read!(Path.join(@mimir_role_dir, "tasks/main.yaml"))

      assert content =~ "mimir_version"
      assert content =~ "mimir-config.yaml.j2"
      assert content =~ "mimir_systemd.service.j2"
      assert content =~ "name: mimir"
    end
  end

  describe "mimir_db role — defaults" do
    test "pins a Mimir version and the shared HTTP port" do
      content = File.read!(Path.join(@mimir_role_dir, "defaults/main.yaml"))

      assert content =~ "mimir_version:"
      assert content =~ "mimir_http_port: 8080"
    end
  end

  describe "mimir_db role — config template" do
    test "runs monolithic mode with filesystem blocks storage and the ruler enabled" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/mimir-config.yaml.j2"))

      assert content =~ "target: all"
      assert content =~ "backend: filesystem"
      assert content =~ "ruler:"
      assert content =~ "enable_api: true"
      assert content =~ "http_listen_port: {{ mimir_http_port }}"
    end

    test "pins prometheus_http_prefix so the Grafana datasource query path can't drift with Mimir versions" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/mimir-config.yaml.j2"))

      assert content =~ "api:"
      assert content =~ "prometheus_http_prefix: /prometheus"
    end
  end

  # SECTION: alloy metrics pipeline (raw j2 — structural assertions)

  describe "alloy_config.alloy.j2 — metrics pipeline" do
    @alloy_path Path.join(@priv_roles_dir, "grafana_alloy/templates/alloy_config.alloy.j2")

    test "scrapes node_exporter and app metrics locally, remote_writes to Mimir, no ec2_sd" do
      content = File.read!(@alloy_path)

      assert content =~ "{% if grafana_mimir_url is defined %}"
      assert content =~ "localhost:9100"
      assert content =~ "{% if app_name is defined %}"
      assert content =~ "localhost:4050"
      assert content =~ ~s(prometheus.remote_write "mimir")
      assert content =~ "{{ grafana_mimir_url }}"
      refute content =~ "ec2_sd"
    end

    test "loki pipeline is byte-identical to the pre-mimir baseline" do
      baseline = File.read!(Path.join(@fixtures_dir, "baseline_alloy_config.alloy.j2"))
      content = File.read!(@alloy_path)

      assert String.starts_with?(content, baseline)
    end
  end

  # SECTION: grafana datasource (raw j2 — structural assertions)

  describe "grafana-datasources.yaml.j2 — Mimir datasource" do
    @datasource_path Path.join(@priv_roles_dir, "grafana_ui/templates/grafana-datasources.yaml.j2")

    test "adds a Mimir prometheus-type datasource under the grafana_mimir_url conditional" do
      content = File.read!(@datasource_path)

      assert content =~ "{% if grafana_mimir_url is defined %}"
      assert content =~ "name: Mimir Metrics"
      assert content =~ "type: prometheus"
      assert content =~ "url: {{ grafana_mimir_url }}/prometheus"
    end

    test "existing Loki + Prometheus datasource entries are untouched" do
      baseline = File.read!(Path.join(@fixtures_dir, "baseline_grafana-datasources.yaml.j2"))
      content = File.read!(@datasource_path)

      assert String.starts_with?(content, baseline)
    end
  end
end
