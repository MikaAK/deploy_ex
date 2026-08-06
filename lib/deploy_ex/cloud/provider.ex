defmodule DeployEx.Cloud.Provider do
  @moduledoc """
  Descriptor behaviour every cloud provider implements.

  A descriptor declares what a provider IS; `DeployEx.Cloud` derives dispatch from it, so
  registering a provider costs one descriptor module plus one registry entry rather than
  edits scattered through the dispatcher.

  Slots a provider has not implemented yet return `nil`, and `capabilities/0` simply omits
  the key. Both surface as `{:error, %ErrorMessage{code: :not_implemented}}` at the call
  site instead of a crash or a silent nil.
  """

  @typedoc "Capability name to the module implementing that capability behaviour"
  @type capabilities :: %{optional(atom()) => module()}

  @typedoc "Where the inventory for this provider comes from and what it renders to"
  @type inventory :: %{strategy: atom(), template: String.t(), filename: String.t()}

  @doc "Map of capability name to implementing module. Unimplemented capabilities are omitted."
  @callback capabilities() :: capabilities()

  @doc "NimbleOptions schema validating this provider's config namespace at task start."
  @callback config_schema() :: keyword()

  @doc "Terraform backend template identifier, or nil until the provider's phase fills it."
  @callback backend_template() :: atom() | nil

  @doc "Strategy used to mark an instance as finished provisioning."
  @callback completion_marker() :: atom() | nil

  @doc "Inventory strategy, source template path and rendered filename."
  @callback inventory() :: inventory() | nil

  @doc "SSH user to use when the neutral `:ssh_user` config is unset."
  @callback default_ssh_user() :: String.t() | nil

  @doc "Module adapting `DeployEx.Cloud.CliRunner` to this provider's CLI, or nil if unused."
  @callback cli_adapter() :: module() | nil
end
