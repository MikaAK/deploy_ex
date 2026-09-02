defmodule DeployEx.MimirRoleTest do
  use ExUnit.Case, async: true

  # priv/ansible/roles/mimir_db and its downstream j2/yaml templates are Ansible/Jinja
  # content, not Elixir-rendered — covered here via raw structural/content assertions
  # (template exemption per the sprint contract; deeper render-diff done manually with
  # the local ansible-bundled jinja2 as evidence, not as a committed `mix test` dependency).
  #
  # Baseline fixtures under test/support/fixtures/mimir/{prometheus_db_role,
  # baseline_alloy_config.alloy.j2} are byte-identical captures of the pre-mimir
  # tree (main @ e06649a) — untouched since capture except
  # prometheus_db_role/templates/prometheus.service.j2, which was bumped
  # forward to match the RequiresMountsFor=/data + After=local-fs.target lines
  # the D5 combined mount lane (item C, approved, unrelated to mimir) added —
  # that file is now a pin on "last approved state", not on e06649a specifically.
  # `@expected_loki_pipeline` below is NOT a main-provenance capture: it's that
  # same baseline with the one known post-sprint delta (the app_name default
  # filter, item 2 of the 2026-08-27 fidelity review) applied on top, asserted
  # explicitly so the delta itself stays pinned instead of silently drifting
  # into the fixture.

  @priv_roles_dir Path.expand("../../priv/ansible/roles", __DIR__)
  @mimir_role_dir Path.join(@priv_roles_dir, "mimir_db")
  @prometheus_role_dir Path.join(@priv_roles_dir, "prometheus_db")
  @fixtures_dir Path.expand("../support/fixtures/mimir", __DIR__)

  @main_alloy_config File.read!(Path.join(@fixtures_dir, "baseline_alloy_config.alloy.j2"))
  @app_name_pre_fix ~s[replacement  = "{{ app_name }}"]
  @app_name_post_fix ~s[replacement  = "{{ app_name | default('') }}"]
  @expected_loki_pipeline String.replace(@main_alloy_config, @app_name_pre_fix, @app_name_post_fix)

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

    test "the role_path-resolved rules file is byte-identical to prometheus_db's canonical template (rendered-content equality, not a path-string grep)" do
      tasks_content = File.read!(Path.join(@mimir_role_dir, "tasks/main.yaml"))
      assert tasks_content =~ "{{ role_path }}/../prometheus_db/templates/prometheus-rules.yaml.j2"

      # Resolve the exact relative path Ansible computes for `role_path` when
      # running the mimir_db role (its own directory) and read what that
      # reference actually points at on disk — proving content equality, not
      # just that the src: line mentions the right-looking string.
      resolved_rules_path =
        @mimir_role_dir
        |> Path.join("../prometheus_db/templates/prometheus-rules.yaml.j2")
        |> Path.expand()

      canonical_rules_path = Path.expand(Path.join(@prometheus_role_dir, "templates/prometheus-rules.yaml.j2"))

      assert resolved_rules_path === canonical_rules_path
      assert File.read!(resolved_rules_path) === File.read!(canonical_rules_path)
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

    test "asserts /data is a mounted filesystem before writing Mimir data there (guards against filling the root volume)" do
      content = File.read!(Path.join(@mimir_role_dir, "tasks/main.yaml"))

      assert content =~ "assert:"
      assert content =~ ~s[selectattr('mount', 'equalto', '/data')]
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

    test "ruler_storage uses the local backend so the ruler actually loads rule groups from disk" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/mimir-config.yaml.j2"))

      assert content =~ ~r/ruler_storage:\s*\n\s*backend: local/
      assert content =~ ~r/local:\s*\n\s*directory: \/data\/mimir\/rules/
      refute content =~ ~r/ruler_storage:\s*\n\s*filesystem:/
    end
  end

  # SECTION: alloy metrics pipeline (raw j2 — structural assertions)

  describe "alloy_config.alloy.j2 — metrics pipeline" do
    @alloy_path Path.join(@priv_roles_dir, "grafana_alloy/templates/alloy_config.alloy.j2")
    @alloy_defaults_path Path.join(@priv_roles_dir, "grafana_alloy/defaults/main.yaml")

    test "scrapes node_exporter and app metrics locally, remote_writes to Mimir, no ec2_sd" do
      content = File.read!(@alloy_path)

      assert content =~ "{% if grafana_mimir_url_configured %}"
      assert content =~ "localhost:9100"
      assert content =~ "{% if app_name is defined %}"
      assert content =~ "localhost:{{ alloy_app_metrics_port }}"
      assert content =~ ~s(prometheus.remote_write "mimir")
      assert content =~ "{{ grafana_mimir_url }}"
      refute content =~ "ec2_sd"
    end

    # The app scrape port used to be the literal `4050` — every consumer whose apps
    # expose metrics on a different port got a Mimir that looked healthy (node_exporter
    # metrics flow fine) while receiving zero application metrics. `alloy_app_metrics_port`
    # is now a role default (grafana_alloy/defaults/main.yaml), and the template reads it
    # bare — no `| default(4050)` filter — because a role default is always in scope when
    # the role renders its own template; a filter would just be a second, driftable copy
    # of the same number.
    test "the app scrape port is the alloy_app_metrics_port variable, read bare with no default() filter" do
      content = File.read!(@alloy_path)

      assert content =~ ~s("__address__" = "localhost:{{ alloy_app_metrics_port }}",)
      refute content =~ "alloy_app_metrics_port | default"
      refute content =~ "alloy_app_metrics_port|default"
      refute content =~ "localhost:4050"
    end

    test "defaults/main.yaml declares alloy_app_metrics_port: 4050 (the single source of truth)" do
      content = File.read!(@alloy_defaults_path)

      assert content =~ "alloy_app_metrics_port: 4050"
    end

    test "the journal relabel rule's app_name reference defaults instead of crashing monitoring-node plays" do
      content = File.read!(@alloy_path)

      # Every monitoring setup playbook (grafana_ui, loki_log_aggregator,
      # prometheus_db, mimir_db) now carries grafana_alloy but never sets
      # `app_name` — an unguarded {{ app_name }} raises AnsibleUndefinedVariable
      # and aborts the whole play.
      refute content =~ @app_name_pre_fix
      assert content =~ @app_name_post_fix
    end

    test "the ONLY delta from main's loki pipeline is the app_name default filter" do
      content = File.read!(@alloy_path)

      assert String.starts_with?(content, @expected_loki_pipeline)
    end

    test "labels scraped series job=nodes/job=apps so the shared NoNodesDiscovered/NoAppsDiscovered/TargetDown rules stay live under push" do
      content = File.read!(@alloy_path)

      assert content =~ ~r/prometheus\.scrape "node_exporter" \{\s*\n\s*job_name\s*=\s*"nodes"/
      assert content =~ ~r/prometheus\.scrape "app" \{\s*\n\s*job_name\s*=\s*"apps"/
    end

    test "attaches instance + instance_id labels to pushed series, mirroring prometheus.yaml.j2's EC2 relabeling" do
      content = File.read!(@alloy_path)

      assert content =~ ~s["instance"    = "{{ inventory_hostname }}"]
      assert content =~ ~s["instance_id" = "{{ instance_id | default('unknown') }}"]
    end

    test "everything added after the loki pipeline is gated behind one balanced {% if grafana_mimir_url_configured %} block — nothing leaks outside it" do
      content = File.read!(@alloy_path)

      assert String.starts_with?(content, @expected_loki_pipeline)

      remainder =
        content
        |> String.trim_leading(@expected_loki_pipeline)
        |> String.trim_trailing()

      assert String.starts_with?(remainder, "{% if grafana_mimir_url_configured %}")
      assert String.ends_with?(remainder, "{% endif %}")

      open_tags = remainder |> String.split(~r/\{%\s*if\s+.+?\s*%\}/) |> length() |> Kernel.-(1)
      close_tags = remainder |> String.split(~r/\{%\s*endif\s*%\}/) |> length() |> Kernel.-(1)

      assert open_tags > 0
      assert open_tags === close_tags
    end
  end

  # SECTION: grafana datasource (raw j2 — structural assertions)

  describe "grafana-datasources.yaml.j2 — Mimir datasource" do
    @datasource_path Path.join(@priv_roles_dir, "grafana_ui/templates/grafana-datasources.yaml.j2")

    test "adds a Mimir prometheus-type datasource under the grafana_mimir_url_configured conditional" do
      content = File.read!(@datasource_path)

      assert content =~ "{% if grafana_mimir_url_configured %}"
      assert content =~ "name: Mimir Metrics"
      assert content =~ "type: prometheus"
      assert content =~ "url: {{ grafana_mimir_url }}/prometheus"
    end

    test "existing Loki entry is untouched" do
      loki_entry = """
      apiVersion: 1

      datasources:
        - name: Loki Logs
          type: loki
          user: $USER
          url: {{ grafana_loki_url }}
      """

      content = File.read!(@datasource_path)

      assert String.starts_with?(content, String.trim_trailing(loki_entry))
    end

    test "wraps the Prometheus entry in {% if grafana_prometheus_url is defined %} so --no-prometheus + mimir renders instead of crashing" do
      content = File.read!(@datasource_path)

      assert content =~ "{% if grafana_prometheus_url is defined %}"
      assert content =~ "name: Prometheus Metrics"

      # The Prometheus block must be closed before the Mimir block opens —
      # not one giant span covering both (which would make Mimir's datasource
      # disappear whenever --no-prometheus is set, defeating the replacement bar).
      prometheus_if = :binary.match(content, "{% if grafana_prometheus_url is defined %}") |> elem(0)
      mimir_if = :binary.match(content, "{% if grafana_mimir_url_configured %}") |> elem(0)
      endif_positions = for [{pos, _}] <- Regex.scan(~r/\{% endif %\}/, content, return: :index), do: pos

      prometheus_endif = Enum.find(endif_positions, &(&1 > prometheus_if))

      assert prometheus_if < prometheus_endif
      assert prometheus_endif < mimir_if
    end
  end
end
