defmodule DeployEx.ConfigTest do
  use ExUnit.Case, async: true

  alias DeployEx.Config

  describe "aws_availability_zone/1" do
    test "defaults to the given region's 'a' zone" do
      assert Config.aws_availability_zone("us-east-1") === "us-east-1a"
    end

    test "defaults to aws_region/0's zone when no region argument is given" do
      assert Config.aws_availability_zone() === "#{Config.aws_region()}a"
    end
  end

  describe "cloud_provider/0" do
    test "defaults to :aws when nothing is configured" do
      assert Config.cloud_provider() === :aws
    end
  end

  describe "provider_setting/2 — generic provider config namespace reader (LT-OCI review-fix)" do
    test "reads a real, seeded key from the :oci namespace" do
      assert Config.provider_setting(:oci, :resource_group) === "OCI Test Backend"
    end

    test "reads nil for an unset key in a real namespace" do
      assert is_nil(Config.provider_setting(:oci, :vcn_cidr))
    end

    test "reads nil for a provider with no configured namespace at all" do
      assert is_nil(Config.provider_setting(:gcp, :region))
    end
  end

  describe "oci_setting/1 — delegates to provider_setting/2" do
    test "reads the same value as provider_setting(:oci, key)" do
      assert Config.oci_setting(:resource_group) === Config.provider_setting(:oci, :resource_group)
      assert Config.oci_setting(:resource_group) === "OCI Test Backend"
    end
  end
end
