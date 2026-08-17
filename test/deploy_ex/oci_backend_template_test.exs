defmodule DeployEx.OciBackendTemplateTest do
  use ExUnit.Case, async: true

  @template DeployExHelpers.priv_folder("terraform/providers/oci/providers.tf.eex")

  @assigns [
    terraform_backend: :s3,
    oci_region: "ap-seoul-1",
    oci_namespace: "axm8ic8kr5of",
    oci_state_bucket: "opgg-terraform",
    oci_state_key: "oracle/ap-seoul-1/opgg-umbrella-dev/terraform.tfstate",
    oci_state_profile: "opgg-oci-compat"
  ]

  defp render(overrides) do
    EEx.eval_file(@template, assigns: Keyword.merge(@assigns, overrides))
  end

  test "renders the compat backend when a state bucket is configured" do
    rendered = render([])

    assert rendered =~ ~s(backend "s3")
    assert rendered =~ ~s(bucket  = "opgg-terraform")
    assert rendered =~ ~s(key     = "oracle/ap-seoul-1/opgg-umbrella-dev/terraform.tfstate")
    assert rendered =~ ~s(profile = "opgg-oci-compat")
    assert rendered =~ "https://axm8ic8kr5of.compat.objectstorage.ap-seoul-1.oraclecloud.com"
    assert rendered =~ "skip_s3_checksum            = true"
    assert rendered =~ "use_path_style              = true"
  end

  test "omits the profile line when no state profile is configured" do
    rendered = render(oci_state_profile: nil)

    assert rendered =~ ~s(backend "s3")
    refute rendered =~ "profile"
  end

  test "renders no backend at all when the state bucket is absent" do
    rendered = render(oci_state_bucket: nil)

    refute rendered =~ "backend"
    refute rendered =~ "compat.objectstorage"
  end

  test "renders no backend when the terraform backend is :local" do
    rendered = render(terraform_backend: :local)

    refute rendered =~ "backend"
  end

  describe "managed postgres template" do
    test "database.tf declares the psql system with durable storage and an ingress NSG" do
      contents = "terraform/providers/oci/database.tf" |> DeployExHelpers.priv_folder() |> File.read!()

      assert contents =~ ~s(resource "oci_psql_db_system" "database")
      assert contents =~ "for_each = var.resource_databases"
      assert contents =~ "is_regionally_durable = try(each.value.regionally_durable, false)"
      assert contents =~ ~s(resource "oci_core_network_security_group" "database")
      assert contents =~ ~s(resource "oci_core_subnet" "database_private")
      assert contents =~ "prohibit_public_ip_on_vnic = true"
      assert contents =~ "min = 5432"
      assert contents =~ ~s(password_type = "PLAIN_TEXT")
    end

    test "the oci variables template declares resource_databases with an empty default" do
      contents = "terraform/providers/oci/variables.tf.eex" |> DeployExHelpers.priv_folder() |> File.read!()

      assert contents =~ ~s(variable "resource_databases")
    end
  end
end
