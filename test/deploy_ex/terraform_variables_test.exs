defmodule DeployEx.TerraformVariablesTest do
  use ExUnit.Case, async: true

  alias DeployEx.TerraformVariables

  describe "terraform_clickhouse_variables/2" do
    test "renders nothing on oci unless --clickhouse is passed" do
      assert TerraformVariables.terraform_clickhouse_variables([], :oci) === ""
    end

    test "renders a DatabaseKey-tagged entry on oci when opted in" do
      rendered = TerraformVariables.terraform_clickhouse_variables([clickhouse: true], :oci)

      assert rendered =~ "_clickhouse = {"
      assert rendered =~ ~s(DatabaseKey = ")
      assert rendered =~ "_clickhouse\""
      assert rendered =~ ~s(shape       = "VM.Standard.E6.Flex")
    end

    test "renders nothing on aws even when opted in — aws users hand-write the entry" do
      assert TerraformVariables.terraform_clickhouse_variables([clickhouse: true], :aws) === ""
    end
  end

  describe "generate_terraform_release_variables/2" do
    test "T18: oci clause discovers load_balancer via a commented example block" do
      rendered = TerraformVariables.generate_terraform_release_variables("my_app", :oci)

      assert rendered =~ ~r/#\s*load_balancer\s*=\s*\{/
      assert rendered =~ ~r/#\s*enable\s*=\s*true/
      assert rendered =~ ~r/#\s*enable_https\s*=\s*false/
      assert rendered =~ ~r/#\s*reserved_ip_ocid\s*=\s*null/
      assert rendered =~ ~r/#\s*health_check\s*=\s*\{/
      assert rendered =~ ~r/#\s*path\s*=/
      assert rendered =~ ~r/#\s*return_code\s*=/
      assert rendered =~ ~r/#\s*https_return_code\s*=/
      assert rendered =~ ~r/#\s*unhealthy_threshold\s*=/
      assert rendered =~ ~r/#\s*timeout\s*=/
      assert rendered =~ ~r/#\s*interval\s*=/
    end

    test "T18: aws clause is byte-identical to the current pinned string" do
      rendered = TerraformVariables.generate_terraform_release_variables("my_app", :aws)

      assert rendered === String.trim_trailing("""
          my_app = {
            name = "My App"
            tags = {
              Vendor = "Self"
              Type   = "Self Made"
            }

            # Autoscaling Configuration (optional)
            # Uncomment and configure to enable AWS Auto Scaling Groups
            # autoscaling = {
            #   enable             = true
            #   min_size           = 1
            #   max_size           = 5
            #   desired_capacity   = 2
            #   cpu_target_percent = 60
            # }
          }
      """, "\n")
    end
  end

  describe "terraform_rabbitmq_variables/2" do
    test "renders nothing on oci unless --rabbitmq is passed" do
      assert TerraformVariables.terraform_rabbitmq_variables([], :oci) === ""
    end

    test "renders a DatabaseKey-tagged single node on oci when opted in" do
      rendered = TerraformVariables.terraform_rabbitmq_variables([rabbitmq: true], :oci)

      assert rendered =~ "_rabbitmq = {"
      assert rendered =~ "_rabbitmq\""
      refute rendered =~ "instance_count"
    end

    test "renders nothing on aws" do
      assert TerraformVariables.terraform_rabbitmq_variables([rabbitmq: true], :aws) === ""
    end
  end

  describe "terraform_sentry_variables/2 on oci" do
    test "renders nothing when --no-sentry is passed" do
      assert TerraformVariables.terraform_sentry_variables([no_sentry: true], :oci) === ""
    end

    test "renders the oci-shaped sentry node by default" do
      rendered = TerraformVariables.terraform_sentry_variables([], :oci)

      assert rendered =~ ~s(shape       = "VM.Standard.E5.Flex")
      assert rendered =~ "ocpus       = 1"
      assert rendered =~ "memory_gbs  = 8"
      assert rendered =~ "boot_volume_size_gbs = 100"
      assert rendered =~ "assign_public_ip     = true"
      assert rendered =~ ~s(MonitoringKey = "sentry")

      refute rendered =~ "ebs"
      refute rendered =~ "enable_eip"
      refute rendered =~ "instance_availability_zone"
    end
  end
end
