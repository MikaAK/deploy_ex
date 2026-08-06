defmodule DeployEx.Cloud.Providers.Oci do
  @moduledoc """
  Descriptor skeleton for Oracle Cloud Infrastructure.

  Every slot below is deliberately unfilled. OCI implementations arrive per phase, and a
  slot invented ahead of its phase would be untested guesswork that reads as working code.
  Unfilled slots surface as `{:error, %ErrorMessage{code: :not_implemented}}`.

  The config schema is the exception: it is strict from the start so a typo'd key fails at
  task start rather than mid-apply. Every key is optional — the schema catches mistakes, it
  does not force configuration.
  """

  @behaviour DeployEx.Cloud.Provider

  @config_schema [
    region: [type: {:or, [:string, nil]}],
    profile: [type: {:or, [:string, nil]}],
    compartment_id: [type: {:or, [:string, nil]}],
    namespace: [type: {:or, [:string, nil]}],
    availability_domain: [type: {:or, [:string, nil]}],
    base_image: [type: {:or, [:keyword_list, :string, nil]}],
    shape: [type: {:or, [:string, nil]}],
    shape_ocpus: [type: {:or, [:pos_integer, nil]}],
    shape_memory_gbs: [type: {:or, [:pos_integer, nil]}],
    release_bucket: [type: {:or, [:string, nil]}],
    release_state_bucket: [type: {:or, [:string, nil]}],
    log_bucket: [type: {:or, [:string, nil]}],
    log_region: [type: {:or, [:string, nil]}],
    resource_group: [type: {:or, [:string, nil]}]
  ]

  @impl DeployEx.Cloud.Provider
  def capabilities, do: %{}

  @impl DeployEx.Cloud.Provider
  def config_schema, do: @config_schema

  # Filled by Phase 2 (terraform environment).
  @impl DeployEx.Cloud.Provider
  def backend_template, do: nil

  # Filled by Phase 2 (cloud-init completion marker, spike S5).
  @impl DeployEx.Cloud.Provider
  def completion_marker, do: nil

  # Filled by Phase 4 (static inventory generator).
  @impl DeployEx.Cloud.Provider
  def inventory, do: nil

  # Decided by spike S3 at Phase 2, threaded at Phase 3.3.
  @impl DeployEx.Cloud.Provider
  def default_ssh_user, do: nil

  # Filled by Phase 3 (oci CLI adapter).
  @impl DeployEx.Cloud.Provider
  def cli_adapter, do: nil
end
