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
end
