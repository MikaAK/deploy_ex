defmodule DeployExHelpersTest do
  @moduledoc """
  Focused test for `DeployExHelpers.parse_provider_opt!/1` — the shared `--provider` CLI flag
  validator the load_test mix tasks route through (LT-OCI review-fix item 7: OptionParser was
  silently swallowing an unrecognized `--provider` value, so `--provider oci` ran against AWS).
  """

  use ExUnit.Case, async: true

  describe "parse_provider_opt!/1" do
    test "leaves opts unchanged when :provider is absent" do
      assert DeployExHelpers.parse_provider_opt!(quiet: true) === [quiet: true]
    end

    test "replaces a valid provider string with its atom" do
      assert DeployExHelpers.parse_provider_opt!(provider: "oci", quiet: true) ===
               [provider: :oci, quiet: true]
    end

    test "raises Mix.Error naming the bad value for an unrecognized provider string" do
      assert_raise Mix.Error, ~r/gcp/, fn ->
        DeployExHelpers.parse_provider_opt!(provider: "gcp")
      end
    end
  end
end
