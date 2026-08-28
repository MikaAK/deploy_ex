defmodule DeployEx.MimirTest do
  use ExUnit.Case, async: true

  alias DeployEx.Mimir

  # Single source of truth for mimir render content, called by both the real
  # Mix tasks (Terraform.Build, Ansible.Build) and the render-only test
  # harness (PrivRenderer) — a mutation here is caught regardless of which
  # caller a test happens to exercise.

  describe "enabled?/1" do
    test "returns true when :no_mimir is absent" do
      assert Mimir.enabled?([])
    end

    test "returns false when :no_mimir is true" do
      refute Mimir.enabled?(no_mimir: true)
    end

    test "returns true when :no_mimir is explicitly false" do
      assert Mimir.enabled?(no_mimir: false)
    end
  end

  describe "terraform_variables/1" do
    test "returns the mimir_db block with all required fields when enabled" do
      content = Mimir.terraform_variables([])

      assert content =~ "mimir_db = {"
      assert content =~ ~s(name                        = "Mimir Metrics Database")
      assert content =~ ~s(instance_type               = "t3.small")
      assert content =~ "enable_ebs                  = true"
      assert content =~ "instance_ebs_secondary_size = 16"
      assert content =~ ~s(private_ip                  = "10.0.1.70")
      assert content =~ ~s(MonitoringKey = "mimir_db")
    end

    test "returns an empty string when :no_mimir is true" do
      assert Mimir.terraform_variables(no_mimir: true) === ""
    end
  end

  describe "monitoring_setup_playbooks/0" do
    test "lists exactly the three existing monitoring node types" do
      assert Mimir.monitoring_setup_playbooks() === ["grafana_ui", "loki_log_aggregator", "prometheus_db"]
    end
  end
end
