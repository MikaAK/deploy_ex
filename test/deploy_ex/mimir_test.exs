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
      assert content =~ ~s(name                       = "Mimir Metrics Database")
      assert content =~ ~s(instance_type              = "t3.small")
      assert content =~ ~r/ebs\s*=\s*\{/
      assert content =~ ~r/enable_secondary\s*=\s*true/
      assert content =~ ~r/secondary_size\s*=\s*16/
      refute content =~ "enable_ebs"
      refute content =~ "instance_ebs_secondary_size"
      refute content =~ "private_ip"
      assert content =~ ~s(MonitoringKey = "mimir_db")
    end

    test "pins instance_availability_zone from opts when provided" do
      content = Mimir.terraform_variables(availability_zone: "us-east-1c")

      assert content =~ ~s(instance_availability_zone = "us-east-1c")
    end

    test "defaults instance_availability_zone when opts omits it" do
      content = Mimir.terraform_variables([])

      assert content =~ ~s(instance_availability_zone = "#{DeployEx.Config.aws_availability_zone()}")
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

  # SECTION: should_write_setup_playbook?/3 — bounding the ansible.build write path
  #
  # These 3 files are consumer-owned generated output (README: "fully owned by
  # you, never overwritten by deploy_ex updates"), not deploy_ex-managed config
  # like group_vars — a build must never silently clobber a customized copy.

  describe "should_write_setup_playbook?/3" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "deploy_ex_mimir_write_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{output_path: Path.join(tmp_dir, "grafana_ui.yaml")}
    end

    test "returns true when the output file does not exist (first delivery)", %{output_path: output_path} do
      assert Mimir.should_write_setup_playbook?(output_path, "rendered content", [])
    end

    test "returns true when the file exists and content is identical to the rendered content (no-op refresh)",
         %{output_path: output_path} do
      File.write!(output_path, "rendered content")

      assert Mimir.should_write_setup_playbook?(output_path, "rendered content", [])
    end

    test "returns false when the file exists and content diverges (protects a customized copy)",
         %{output_path: output_path} do
      File.write!(output_path, "a cfx operator's hand-customized playbook")

      refute Mimir.should_write_setup_playbook?(output_path, "rendered content", [])
    end

    test "returns false when new_only is set and the file exists, even with identical content",
         %{output_path: output_path} do
      File.write!(output_path, "rendered content")

      refute Mimir.should_write_setup_playbook?(output_path, "rendered content", new_only: true)
    end

    test "returns true when new_only is set and the file does not exist", %{output_path: output_path} do
      assert Mimir.should_write_setup_playbook?(output_path, "rendered content", new_only: true)
    end
  end
end
