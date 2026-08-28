defmodule DeployEx.Cloud.Providers.OciTest do
  use ExUnit.Case, async: true

  alias DeployEx.Cloud.Providers.Oci

  test "declares the descriptor behaviour" do
    assert DeployEx.Cloud.Provider in (Oci.module_info(:attributes)[:behaviour] || [])
  end

  test "capabilities/0 exposes the object store and security group and nothing else" do
    assert Oci.capabilities() === %{
             object_store: DeployEx.Cloud.OciObjectStore,
             security: DeployEx.Cloud.OciSecurityGroup
           }
  end

  test "backend_template/0 is :s3 — state rides the S3-compatibility endpoint" do
    assert Oci.backend_template() === :s3
  end

  test "slots not yet filled are nil, not invented" do
    assert is_nil(Oci.completion_marker())
    assert is_nil(Oci.cli_adapter())
  end

  test "inventory/0 declares the static oci CLI generator, not an ansible collection plugin" do
    assert Oci.inventory() === %{
      strategy: :static_oci_cli,
      template: "ansible/providers/oci/oci.yaml.eex",
      filename: "oci.yaml"
    }
  end

  test "default_ssh_user/0 is ubuntu — OCI's Ubuntu images have no admin user" do
    assert Oci.default_ssh_user() === "ubuntu"
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
        shape_memory_gbs: 8,
        subnet_id: "ocid1.subnet.oc1..aaaa",
        availability_domain: "abcd:AP-SEOUL-1-AD-1"
      ]

      assert {:ok, _} = NimbleOptions.validate(config, Oci.config_schema())
    end

    test "accepts an empty config — the schema catches typos, it does not force config" do
      assert {:ok, _} = NimbleOptions.validate([], Oci.config_schema())
    end

    test "EVERY key accepts nil, so an unset System.get_env/1 does not fail task start" do
      nil_config = Enum.map(Oci.config_schema(), fn {key, _spec} -> {key, nil} end)

      assert {:ok, _} = NimbleOptions.validate(nil_config, Oci.config_schema())
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
