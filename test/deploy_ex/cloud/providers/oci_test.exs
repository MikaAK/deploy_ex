defmodule DeployEx.Cloud.Providers.OciTest do
  use ExUnit.Case, async: true

  alias DeployEx.Cloud.Providers.Oci

  test "declares the descriptor behaviour" do
    assert DeployEx.Cloud.Provider in (Oci.module_info(:attributes)[:behaviour] || [])
  end

  test "capabilities/0 is empty — no OCI implementation exists before P3" do
    assert Oci.capabilities() === %{}
  end

  test "slots filled by later phases are nil, not invented" do
    assert is_nil(Oci.backend_template())
    assert is_nil(Oci.completion_marker())
    assert is_nil(Oci.inventory())
    assert is_nil(Oci.default_ssh_user())
    assert is_nil(Oci.cli_adapter())
  end

  describe "config_schema/0" do
    test "accepts the documented key set" do
      config = [
        region: "us-phoenix-1",
        profile: "DEFAULT",
        compartment_id: "ocid1.compartment.oc1..aaaa",
        namespace: "mynamespace",
        shape: "VM.Standard.E5.Flex",
        shape_ocpus: 1,
        shape_memory_gbs: 8
      ]

      assert {:ok, _} = NimbleOptions.validate(config, Oci.config_schema())
    end

    test "accepts an empty config — the schema catches typos, it does not force config" do
      assert {:ok, _} = NimbleOptions.validate([], Oci.config_schema())
    end

    test "REJECTS a typo'd key — this is what makes the strict schema non-vacuous" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               NimbleOptions.validate([regionn: "typo"], Oci.config_schema())
    end

    test "rejects a wrong-typed value" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               NimbleOptions.validate([shape_ocpus: "not-an-integer"], Oci.config_schema())
    end
  end
end
