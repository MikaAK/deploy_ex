defmodule DeployEx.Cloud.OciInfrastructureTest do
  @moduledoc """
  Behavioural tests for `DeployEx.Cloud.OciInfrastructure` — LT-OCI S2. Config-driven
  ("discovery-lite"): every callback reads a value directly out of the `:oci` config
  namespace (via `opts` overrides in these tests, matching `OciCli.setting/2`'s opts-first
  precedence) rather than querying the tenancy, so nothing here needs a live OCI call.
  """

  use ExUnit.Case, async: true

  alias DeployEx.Cloud.OciInfrastructure

  describe "find_network/1" do
    test "honest not_implemented — OCI infra discovery this sprint is subnet/image only" do
      assert {:error, %ErrorMessage{code: :not_implemented}} = OciInfrastructure.find_network([])
    end
  end

  describe "find_subnet/1" do
    test "resolves the configured subnet_id" do
      assert {:ok, "ocid1.subnet.oc1..aaaa"} = OciInfrastructure.find_subnet(oci_subnet_id: "ocid1.subnet.oc1..aaaa")
    end

    test "errors loudly when unset rather than launching into a nil subnet" do
      assert {:error, %ErrorMessage{code: :bad_request, message: message}} = OciInfrastructure.find_subnet([])
      assert message =~ "subnet_id"
    end
  end

  describe "find_image/1" do
    test "resolves a configured string base_image directly as the image OCID" do
      assert {:ok, "ocid1.image.oc1..aaaa"} =
               OciInfrastructure.find_image(oci_base_image: "ocid1.image.oc1..aaaa")
    end

    test "errors loudly when unset" do
      assert {:error, %ErrorMessage{code: :bad_request, message: message}} = OciInfrastructure.find_image([])
      assert message =~ "base_image"
    end

    test "a keyword-list (per-app) base_image is honestly not_implemented this sprint" do
      assert {:error, %ErrorMessage{code: :not_implemented}} =
               OciInfrastructure.find_image(oci_base_image: [my_app: "ocid1.image.oc1..bbbb"])
    end
  end

  describe "find_key_pair/2" do
    test "an explicit :pem opt bypasses directory glob search entirely" do
      assert {:ok, "/tmp/some-key.pem"} = OciInfrastructure.find_key_pair("my-project", pem: "/tmp/some-key.pem")
    end
  end

  describe "find_instance_identity/1" do
    test "returns {:ok, nil} — OCI instance principals use dynamic groups, not a per-launch identity string" do
      assert {:ok, nil} = OciInfrastructure.find_instance_identity([])
    end
  end

  describe "gather_infrastructure/1" do
    test "bundles subnet_id, image_id and key_name from config" do
      opts = [oci_subnet_id: "ocid1.subnet.oc1..aaaa", oci_base_image: "ocid1.image.oc1..aaaa", pem: "/tmp/key.pem"]

      assert {:ok, %{subnet_id: "ocid1.subnet.oc1..aaaa", image_id: "ocid1.image.oc1..aaaa", key_name: "/tmp/key.pem"}} =
               OciInfrastructure.gather_infrastructure(opts)
    end

    test "propagates the first missing piece as an error instead of a partial bundle" do
      assert {:error, %ErrorMessage{code: :bad_request}} =
               OciInfrastructure.gather_infrastructure(oci_base_image: "ocid1.image.oc1..aaaa", pem: "/tmp/key.pem")
    end
  end
end
