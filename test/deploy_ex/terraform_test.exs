defmodule DeployEx.TerraformTest do
  use ExUnit.Case, async: true

  alias DeployEx.Terraform

  describe "parse_args/2 — the shared arg builder plan/apply/drop route through" do
    test "passes an explicit --var-file through untouched" do
      assert Terraform.parse_args(["--var-file", "terraform.tfvars"], :plan) ===
               "--var-file terraform.tfvars"
    end

    test "returns an empty string for no args and no config default" do
      assert Terraform.parse_args([], :plan) === ""
    end

    test "accepts any var-file path verbatim, not just AWS-shaped ones" do
      assert Terraform.parse_args(["--var-file", "providers/oci/terraform.tfvars"], :apply) ===
               "--var-file providers/oci/terraform.tfvars"
    end

    test "leaves a fully-qualified target string unchanged" do
      assert Terraform.parse_args(["--target", "module.ec2_instance[\\\"foo\\\"]"], :destroy) ===
               "--target module.ec2_instance[\\\"foo\\\"]"
    end

    test "leaves a dotted (non-bare) target unchanged, regardless of provider resource naming" do
      assert Terraform.parse_args(["--target", "oci_core_instance.main"], :plan) ===
               "--target oci_core_instance.main"
    end

    test "expands multiple --target flags independently" do
      result = Terraform.parse_args(
        ["--target", "oci_core_vcn.main", "--target", "oci_core_subnet.public"],
        :plan
      )

      assert result === "--target oci_core_vcn.main --target oci_core_subnet.public"
    end

    # Pins build_target_string/1's current behavior: a bare, non-dotted target name is
    # assumed to be an AWS app name and wrapped into the ec2_instance module path. This is
    # the one AWS-module-shaped assumption left in the shared arg builder — a future
    # provider-aware branch (e.g. for OCI's per-app modules) should change this test, not
    # break it silently.
    test "wraps a bare app-name target into the AWS ec2_instance module path (pre-provider-aware baseline)" do
      assert Terraform.parse_args(["--target", "myapp"], :plan) ===
               "--target module.ec2_instance[\\\"myapp\\\"]"
    end
  end

  describe "plan/apply/drop tasks stay provider-neutral" do
    @task_sources [
      "lib/mix/tasks/terraform.plan.ex",
      "lib/mix/tasks/terraform.apply.ex",
      "lib/mix/tasks/terraform.drop.ex"
    ]

    test "hold no hardcoded AWS/S3-specific strings in their command path" do
      Enum.each(@task_sources, fn source_path ->
        source = File.read!(source_path)

        refute source =~ ~r/aws|s3|ec2/i,
               "#{source_path} should stay provider-neutral; found an AWS/S3/EC2 reference"
      end)
    end

    test "each accepts --directory, so any provider's rendered set can be targeted" do
      Enum.each(@task_sources, fn source_path ->
        source = File.read!(source_path)

        assert source =~ "directory: :string",
               "#{source_path} must accept --directory to point at a non-default provider tree"
      end)
    end

    test "each routes its command through DeployEx.Terraform.parse_args/2" do
      Enum.each(@task_sources, fn source_path ->
        source = File.read!(source_path)

        assert source =~ "DeployEx.Terraform.parse_args(args,",
               "#{source_path} must build its tofu invocation through the shared, provider-neutral arg builder"
      end)
    end
  end
end
