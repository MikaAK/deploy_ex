defmodule Mix.Tasks.Terraform.BuildTest do
  use ExUnit.Case, async: true

  # These generators originally lived as private heredocs inside Mix.Tasks.Terraform.Build and
  # were asserted by scraping this file's source. They are now public in
  # DeployEx.TerraformVariables (one copy, both callers — terraform.build and priv_renderer),
  # so the AWS-clause output is asserted directly. See test/deploy_ex/priv_renderer_test.exs
  # for the render-level assertions.

  alias DeployEx.TerraformVariables

  describe "terraform_redis_variables/2 (AWS)" do
    test "uses nested ebs form with secondary_size 16" do
      block = TerraformVariables.terraform_redis_variables([], :aws)

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*16/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "pins instance_availability_zone from opts and drops the fixed private_ip" do
      block = TerraformVariables.terraform_redis_variables([availability_zone: "us-test-9z"], :aws)

      assert block =~ ~s(instance_availability_zone = "us-test-9z")
      refute block =~ "private_ip"
    end
  end

  describe "terraform_sentry_variables/2 (AWS)" do
    test "pins instance_availability_zone from opts" do
      block = TerraformVariables.terraform_sentry_variables([availability_zone: "us-test-9z"], :aws)

      assert block =~ ~s(instance_availability_zone = "us-test-9z")
      refute block =~ "private_ip"
    end
  end

  describe "terraform_loki_variables/2 (AWS)" do
    test "uses nested ebs form with secondary_size 8" do
      block = TerraformVariables.terraform_loki_variables([], :aws)

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*8/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "pins instance_availability_zone from opts and drops the fixed private_ip" do
      block = TerraformVariables.terraform_loki_variables([availability_zone: "us-test-9z"], :aws)

      assert block =~ ~s(instance_availability_zone = "us-test-9z")
      refute block =~ "private_ip"
    end
  end

  describe "terraform_grafana_variables/2 (AWS)" do
    test "uses nested ebs form with secondary_size 8, enable_eip untouched" do
      block = TerraformVariables.terraform_grafana_variables([], :aws)

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*8/
      assert block =~ ~r/enable_eip\s*=\s*true/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "pins instance_availability_zone from opts" do
      block = TerraformVariables.terraform_grafana_variables([availability_zone: "us-test-9z"], :aws)

      assert block =~ ~s(instance_availability_zone = "us-test-9z")
    end
  end

  describe "terraform_prometheus_variables/2 (AWS)" do
    test "uses nested ebs form with secondary_size 16" do
      block = TerraformVariables.terraform_prometheus_variables([], :aws)

      assert block =~ ~r/ebs\s*=\s*\{/
      assert block =~ ~r/enable_secondary\s*=\s*true/
      assert block =~ ~r/secondary_size\s*=\s*16/
      refute block =~ "enable_ebs"
      refute block =~ "instance_ebs_secondary_size"
    end

    test "pins instance_availability_zone from opts and drops the fixed private_ip" do
      block = TerraformVariables.terraform_prometheus_variables([availability_zone: "us-test-9z"], :aws)

      assert block =~ ~s(instance_availability_zone = "us-test-9z")
      refute block =~ "private_ip"
    end
  end

  describe "build_opts/1 — availability_zone (behavioral, not source-regex)" do
    # build_opts/1 is the same opts pipeline run/1 feeds into every
    # terraform_*_variables/1 call — testing it directly (rather than only
    # grepping source) proves the actual value threaded through opts, not
    # just that some matching text exists somewhere in the file.

    test "defaults opts[:availability_zone] from opts[:aws_region] when no CLI flag is given" do
      opts = Mix.Tasks.Terraform.Build.build_opts(["--aws-region", "us-east-1"])

      assert opts[:availability_zone] === "us-east-1a"
    end

    test "--availability-zone overrides the region-derived default" do
      opts = Mix.Tasks.Terraform.Build.build_opts(["--aws-region", "us-east-1", "--availability-zone", "us-east-1c"])

      assert opts[:availability_zone] === "us-east-1c"
    end
  end
end
