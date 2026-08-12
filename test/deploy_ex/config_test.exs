defmodule DeployEx.ConfigTest do
  use ExUnit.Case, async: true

  alias DeployEx.Config

  describe "cloud_provider/0" do
    test "defaults to :aws when nothing is configured" do
      assert Config.cloud_provider() === :aws
    end
  end
end
