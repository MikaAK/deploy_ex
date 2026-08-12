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
end
