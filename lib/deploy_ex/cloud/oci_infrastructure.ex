defmodule DeployEx.Cloud.OciInfrastructure do
  @moduledoc """
  Network, image and key discovery for OCI. Config-driven ("discovery-lite") rather than
  tenancy-queried like `DeployEx.AwsInfrastructure`: every callback reads a value directly out
  of the `:oci` config namespace (via `DeployEx.Cloud.OciCli.setting/2`) instead of searching
  the compartment, so launching an ad-hoc instance never needs a live OCI call just to find
  out what to attach to. Missing config fails loudly (`:bad_request`) rather than launching
  into a nil subnet/image.
  """

  @behaviour DeployEx.Cloud.Infrastructure

  alias DeployEx.Cloud.OciCli

  @impl DeployEx.Cloud.Infrastructure
  def find_network(_opts \\ []) do
    {:error,
     ErrorMessage.not_implemented(
       "OCI network (VCN) discovery is not implemented — subnet_id is configured directly, see find_subnet/1"
     )}
  end

  @impl DeployEx.Cloud.Infrastructure
  def find_subnet(opts \\ []) do
    require_setting(opts, :subnet_id)
  end

  # CONTRACT ASYMMETRY, deliberate: AWS's find_key_pair returns a key-pair NAME (an EC2
  # registry handle passed to RunInstances); OCI has no key-pair registry — the public key
  # travels in launch metadata (ssh_authorized_keys) and what callers need locally is the
  # PEM PATH for SSH. Both satisfy "the key material the create path needs" under one
  # callback; consumers must not assume the value's shape across providers.
  @impl DeployEx.Cloud.Infrastructure
  def find_key_pair(_project_name, opts \\ []) do
    DeployEx.Terraform.find_pem_file(DeployEx.Config.terraform_folder_path(), opts[:pem])
  end

  @impl DeployEx.Cloud.Infrastructure
  def find_image(opts \\ []) do
    case OciCli.setting(opts, :base_image) do
      nil -> missing_setting_error(:base_image)
      image when is_binary(image) -> {:ok, image}
      image when is_list(image) -> per_app_image_not_implemented_error(image)
    end
  end

  @doc "Identity the instance assumes, per `DeployEx.Cloud.Infrastructure`."
  @impl DeployEx.Cloud.Infrastructure
  def find_instance_identity(_opts \\ []) do
    # OCI instance principals authorize by dynamic-group membership matched against the
    # instance's OCID (or its compartment) after the fact, not by attaching a named identity
    # at launch time the way an EC2 IAM instance profile does — there is nothing to return
    # here, and that is the honest, working answer, not a gap.
    {:ok, nil}
  end

  @impl DeployEx.Cloud.Infrastructure
  def gather_infrastructure(opts \\ []) do
    with {:ok, subnet_id} <- find_subnet(opts),
         # NOTE: run_instance does NOT read this bundle's subnet_id/image_id — it re-resolves
         # both via require_setting from config (ticket OCI-BUNDLE-VS-CONFIG tracks unifying).
         # The bundle exists so create_instance's preflight fails fast before any launch.
         {:ok, image_id} <- find_image(opts),
         {:ok, key_name} <- find_key_pair(nil, opts) do
      {:ok, %{subnet_id: subnet_id, image_id: image_id, key_name: key_name}}
    end
  end

  defp require_setting(opts, key) do
    case OciCli.setting(opts, key) do
      nil -> missing_setting_error(key)
      value -> {:ok, value}
    end
  end

  defp missing_setting_error(key) do
    {:error,
     ErrorMessage.bad_request(
       "oci #{key} is required (config :deploy_ex, :oci, #{key}: \"...\")",
       %{key: key}
     )}
  end

  defp per_app_image_not_implemented_error(image) do
    {:error,
     ErrorMessage.not_implemented(
       "per-app base_image resolution (keyword-list form) is not implemented this sprint — " <>
         "configure base_image as a single OCID string",
       %{base_image: image}
     )}
  end
end
