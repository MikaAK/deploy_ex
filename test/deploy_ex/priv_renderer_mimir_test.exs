defmodule DeployEx.PrivRendererMimirTest do
  use ExUnit.Case, async: true

  alias DeployEx.PrivRenderer

  # baseline_variables.tf: re-captured 2026-08-28 from build/ip-fix (main @ a930d71 +
  # the DHCP/AZ-pin fix, mimir disabled) — reflects the dropped `private_ip` / added
  # `instance_availability_zone` now shared by redis/loki/grafana/prometheus/sentry.
  # baseline_group_vars_all.yaml: re-captured the same run — the loki/prometheus URL
  # defaults switched from fixed private IPs to FILL_IN_AFTER_FIRST_APPLY placeholders.
  # Both are the byte-identical baseline that `--no-mimir` must reproduce exactly.
  @fixtures_dir Path.expand("../support/fixtures/mimir", __DIR__)
  @baseline_variables_tf File.read!(Path.join(@fixtures_dir, "baseline_variables.tf"))
  @baseline_group_vars File.read!(Path.join(@fixtures_dir, "baseline_group_vars_all.yaml"))

  @prometheus_block """
      prometheus_db = {
        name                        = "Prometheus Metrics Database"
        instance_type               = "t3.micro"
        instance_availability_zone = "#{DeployEx.Config.aws_availability_zone()}"

        ebs = {
          enable_secondary = true
          secondary_size   = 16
        }

        tags = {
          Vendor = "Grafana"
          Type   = "Monitoring"
          MonitoringKey = "prometheus_db"
        }
      },
  """

  @mimir_block """

      mimir_db = {
        name                        = "Mimir Metrics Database"
        instance_type               = "t3.small"
        instance_availability_zone = "#{DeployEx.Config.aws_availability_zone()}"

        ebs = {
          enable_secondary = true
          secondary_size   = 16
        }

        tags = {
          Vendor = "Grafana"
          Type   = "Monitoring"
          MonitoringKey = "mimir_db"
        }
      },
  """

  # `environment: "dev"` pins the "environment" variable's default (line 1 of the
  # rendered variables.tf) to match the fixture below. It does NOT affect bucket
  # names — those are suffixed by the real `Mix.env()` ("test" under `mix test`,
  # same as when the fixture below was captured), independent of this opt.
  defp render_variables_tf(opts) do
    {:ok, temp_dir} = PrivRenderer.render_to_temp(Keyword.put_new(opts, :environment, "dev"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)
    File.read!(Path.join(temp_dir, "terraform/variables.tf"))
  end

  defp render_group_vars(opts) do
    {:ok, temp_dir} = PrivRenderer.render_to_temp(Keyword.put_new(opts, :environment, "dev"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)
    File.read!(Path.join(temp_dir, "ansible/group_vars/all.yaml"))
  end

  # SECTION: Terraform mimir_db variable block

  describe "terraform mimir_db variable block — default (mimir ON)" do
    test "contains the mimir_db block with all required fields" do
      content = render_variables_tf([])

      assert content =~ "mimir_db = {"
      assert content =~ ~s(name                        = "Mimir Metrics Database")
      assert content =~ ~s(instance_type               = "t3.small")
      assert content =~ ~r/ebs\s*=\s*\{/
      assert content =~ ~r/enable_secondary\s*=\s*true/
      assert content =~ ~r/secondary_size\s*=\s*16/
      refute content =~ "enable_ebs"
      refute content =~ "instance_ebs_secondary_size"
      assert content =~ ~s(MonitoringKey = "mimir_db")

      [mimir_block] = Regex.run(~r/mimir_db\s*=\s*\{.*?\n\s*\},/s, content)
      refute mimir_block =~ "private_ip"
    end

    test "adds only the mimir_db block — everything else matches the pre-mimir baseline" do
      content = render_variables_tf([])

      expected = String.replace(@baseline_variables_tf, @prometheus_block, @prometheus_block <> @mimir_block)

      assert content === expected
    end
  end

  describe "terraform mimir_db variable block — --no-mimir" do
    test "omits the mimir_db block" do
      content = render_variables_tf(no_mimir: true)

      refute content =~ "mimir_db"
    end

    test "is byte-identical to the pre-mimir baseline render" do
      content = render_variables_tf(no_mimir: true)

      assert content === @baseline_variables_tf
    end
  end

  # SECTION: Ansible group_vars grafana_mimir_url

  describe "group_vars grafana_mimir_url — default (mimir ON)" do
    test "contains grafana_mimir_url as a fill-after-apply placeholder (mimir_db has no private_ip)" do
      content = render_group_vars([])

      assert content =~ ~s(grafana_mimir_url: "http://FILL_IN_AFTER_FIRST_APPLY:8080")
    end

    test "adds only grafana_mimir_url — everything else matches the pre-mimir baseline" do
      content = render_group_vars([])

      assert String.starts_with?(content, @baseline_group_vars)
      assert content =~ ~s(grafana_mimir_url: "http://FILL_IN_AFTER_FIRST_APPLY:8080")
    end

    test "ends with a trailing newline (POSIX text file convention)" do
      content = render_group_vars([])

      assert String.ends_with?(content, "\n")
    end
  end

  describe "group_vars grafana_mimir_url — --no-mimir" do
    test "omits grafana_mimir_url" do
      content = render_group_vars(no_mimir: true)

      refute content =~ "grafana_mimir_url"
    end

    test "is byte-identical to the pre-mimir baseline render" do
      content = render_group_vars(no_mimir: true)

      assert content === @baseline_group_vars
    end
  end

  # SECTION: app setup playbook — replacement bar (metrics coverage under --no-prometheus)

  defp render_app_setup_playbook(opts) do
    {:ok, temp_dir} = PrivRenderer.render_to_temp(Keyword.put_new(opts, :environment, "dev"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)
    File.read!(Path.join(temp_dir, "ansible/setup/deploy_ex.yaml"))
  end

  describe "app setup playbook — prometheus_exporter kept unless BOTH no_prometheus and no_mimir" do
    test "kept by default (both prometheus and mimir enabled)" do
      content = render_app_setup_playbook([])

      assert content =~ "- prometheus_exporter"
    end

    test "kept with only --no-prometheus — Alloy still needs it to push node_exporter metrics to Mimir" do
      content = render_app_setup_playbook(no_prometheus: true)

      assert content =~ "- prometheus_exporter"
    end

    test "omitted only when BOTH --no-prometheus and --no-mimir — no metrics consumer left" do
      content = render_app_setup_playbook(no_prometheus: true, no_mimir: true)

      refute content =~ "- prometheus_exporter"
    end

    test "kept with only --no-mimir (prometheus still pull-scraping it)" do
      content = render_app_setup_playbook(no_mimir: true)

      assert content =~ "- prometheus_exporter"
    end
  end

  # SECTION: monitoring setup playbooks — grafana_alloy gated on mimir being enabled

  defp render_monitoring_setup_playbook(name, opts) do
    {:ok, temp_dir} = PrivRenderer.render_to_temp(Keyword.put_new(opts, :environment, "dev"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)
    File.read!(Path.join(temp_dir, "ansible/setup/#{name}.yaml"))
  end

  describe "monitoring setup playbooks — grafana_alloy gated on mimir" do
    for name <- ["grafana_ui", "loki_log_aggregator", "prometheus_db"] do
      test "#{name}.yaml includes grafana_alloy by default (mimir ON)" do
        content = render_monitoring_setup_playbook(unquote(name), [])

        assert content =~ "- grafana_alloy"
      end

      test "#{name}.yaml omits grafana_alloy with --no-mimir (nothing to push metrics to)" do
        content = render_monitoring_setup_playbook(unquote(name), no_mimir: true)

        refute content =~ "- grafana_alloy"
      end
    end
  end
end
