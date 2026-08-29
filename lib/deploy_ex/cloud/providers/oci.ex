defmodule DeployEx.Cloud.Providers.Oci do
  @moduledoc """
  Descriptor skeleton for Oracle Cloud Infrastructure.

  Slots fill per phase. One invented ahead of its phase would be untested guesswork that reads
  as working code, so an unfilled slot stays `nil` and surfaces as
  `{:error, %ErrorMessage{code: :not_implemented}}` rather than a plausible default.
  `object_store`, `inventory`, `security`, `machine` and `infrastructure` are filled;
  `completion_marker` and `cli_adapter` are not (the latter has no consumer yet — every
  filled capability already talks to `DeployEx.Cloud.OciCli` directly).

  The config schema is the exception: it is strict from the start so a typo'd key fails at
  task start rather than mid-apply. Every key is optional — the schema catches mistakes, it
  does not force configuration.
  """

  @behaviour DeployEx.Cloud.Provider

  @config_schema [
    region: [type: {:or, [:string, nil]}],
    home_region: [type: {:or, [:string, nil]}],
    profile: [type: {:or, [:string, nil]}],
    auth: [type: {:or, [:string, nil]}],
    compartment_id: [type: {:or, [:string, nil]}],
    namespace: [type: {:or, [:string, nil]}],
    availability_domain: [type: {:or, [:string, nil]}],
    subnet_id: [type: {:or, [:string, nil]}],
    base_image: [type: {:or, [:keyword_list, :string, nil]}],
    shape: [type: {:or, [:string, nil]}],
    shape_ocpus: [type: {:or, [:pos_integer, nil]}],
    shape_memory_gbs: [type: {:or, [:pos_integer, nil]}],
    release_bucket: [type: {:or, [:string, nil]}],
    release_state_bucket: [type: {:or, [:string, nil]}],
    release_state_key: [type: {:or, [:string, nil]}],
    vcn_cidr: [type: {:or, [:string, nil]}],
    state_profile: [type: {:or, [:string, nil]}],
    log_bucket: [type: {:or, [:string, nil]}],
    log_region: [type: {:or, [:string, nil]}],
    resource_group: [type: {:or, [:string, nil]}],
    ssh_public_key: [type: {:or, [:string, nil]}]
  ]

  @impl DeployEx.Cloud.Provider
  def capabilities do
    %{
      object_store: DeployEx.Cloud.OciObjectStore,
      security: DeployEx.Cloud.OciSecurityGroup,
      machine: DeployEx.Cloud.OciMachine,
      infrastructure: DeployEx.Cloud.OciInfrastructure
    }
  end

  @impl DeployEx.Cloud.Provider
  def config_schema, do: @config_schema

  # State rides OCI's S3-compatibility endpoint — there is no native OCI backend in
  # terraform, so the :s3 backend with a Customer Secret Key is the only remote option.
  @impl DeployEx.Cloud.Provider
  def backend_template, do: :s3

  # Filled by Phase 2 (cloud-init completion marker, spike S5).
  @impl DeployEx.Cloud.Provider
  def completion_marker, do: nil

  # Static, not a plugin: no oci ansible collection dependency wanted, so
  # Mix.Tasks.Ansible.Build queries the oci CLI directly and renders this template into a
  # point-in-time snapshot. See priv/ansible/providers/oci/README.md for the generator.
  @impl DeployEx.Cloud.Provider
  def inventory do
    %{strategy: :static_oci_cli, template: "ansible/providers/oci/oci.yaml.eex", filename: "oci.yaml"}
  end

  # OCI's Ubuntu images have no `admin` user (AWS's default) — see
  # priv/ansible/providers/oci/ansible.cfg.eex, which bakes this in directly rather than
  # reading this slot, since ansible.cfg is a static file rendered once, not something a
  # runtime caller looks up per request. Filled for parity with the AWS descriptor and any
  # future caller that needs the ssh user without parsing a rendered ansible.cfg.
  @impl DeployEx.Cloud.Provider
  def default_ssh_user, do: "ubuntu"

  # `DeployEx.Cloud.OciCli` already exists and is the CLI runner every OCI capability
  # (object_store, security, machine, infrastructure) calls directly — but nothing reads this
  # descriptor slot to dispatch to it, so setting it here would be a dangling reference with
  # no consumer. Fill it once something actually looks a provider's cli_adapter up generically.
  @impl DeployEx.Cloud.Provider
  def cli_adapter, do: nil
end
