defmodule DeployEx.Cloud do
  @moduledoc """
  Entry point for provider-aware behaviour lookup.

  Dispatch is DERIVED from provider descriptors rather than written here. This module holds
  no capability or behaviour module names at all — adding a provider costs one registry
  entry plus one descriptor module, and nothing in this file changes.

  A capability the active provider does not implement returns
  `{:error, %ErrorMessage{code: :not_implemented}}` so tasks can surface an honest message
  and exit rather than crashing on a nil module.
  """

  alias DeployEx.Config

  @providers %{
    aws: DeployEx.Cloud.Providers.Aws,
    oci: DeployEx.Cloud.Providers.Oci
  }

  @doc """
  Resolves the module implementing `capability` for the active provider.

  `:provider` in `opts` overrides the configured provider and accepts either a registered
  atom key or a descriptor module. The module form is the injection seam used by tests,
  which cannot call `Application.put_env/3`.
  """
  @spec capability(atom(), keyword()) :: {:ok, module()} | {:error, ErrorMessage.t()}
  def capability(capability, opts \\ []) do
    with {:ok, descriptor} <- opts |> active_provider() |> fetch_descriptor() do
      fetch_capability(descriptor, capability)
    end
  end

  @doc """
  Inventory strategy/template/filename for a provider's descriptor.

  Returns `{:error, %ErrorMessage{code: :not_implemented}}` both when the provider itself is
  unregistered and when it has not filled its `inventory/0` slot yet — an unfilled slot means
  a provider still short of that phase, not a bug in this lookup. The sole consumer today is
  `Mix.Tasks.Ansible.{Build,Setup,Deploy,Ping}`, which all resolve the live inventory filename
  through here so a provider switch can never leave one of them checking the other's file.
  """
  @spec inventory(atom() | module()) ::
          {:ok, DeployEx.Cloud.Provider.inventory()} | {:error, ErrorMessage.t()}
  def inventory(provider) do
    with {:ok, descriptor} <- fetch_descriptor(provider) do
      case descriptor.inventory() do
        nil ->
          {:error,
           ErrorMessage.not_implemented("#{inspect(descriptor)} has not implemented inventory/0", %{
             provider: descriptor
           })}

        inventory ->
          {:ok, inventory}
      end
    end
  end

  @doc """
  Provider these opts resolve to: an explicit `:provider` override, else the configured one.

  Public so the resolution is testable on its own. Every dispatch path routes through it, so
  a hardcoded provider anywhere else is a defect this function's tests will not hide.
  """
  @spec active_provider(keyword()) :: atom() | module()
  def active_provider(opts), do: opts[:provider] || Config.cloud_provider()

  @doc """
  Validates a provider's configuration namespace against its descriptor schema.

  The environment is an explicit argument so the check is a pure function. The convenience
  arities below read the real application environment.
  """
  @spec validate_config(atom() | module(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def validate_config(provider, env) when is_list(env) do
    if Keyword.keyword?(env) do
      with {:ok, descriptor} <- fetch_descriptor(provider) do
        validate_against_schema(descriptor, env, provider)
      end
    else
      invalid_config_error(provider, env)
    end
  end

  def validate_config(provider, env), do: invalid_config_error(provider, env)

  @spec validate_config(atom() | keyword()) :: :ok | {:error, ErrorMessage.t()}
  def validate_config(provider_or_opts \\ [])

  def validate_config(opts) when is_list(opts) do
    provider = active_provider(opts)

    validate_config(provider, config_env(provider))
  end

  def validate_config(provider), do: validate_config(provider, config_env(provider))

  @doc "Registered provider keys."
  @spec providers() :: [atom()]
  def providers, do: Map.keys(@providers)

  @doc """
  Parses a CLI `--provider` flag value into a registered provider atom.

  Never `String.to_atom/1`s the input — an unrecognized value errors instead of interning a
  fresh atom for every typo a caller makes. `nil` (the flag was not given) resolves to `nil`,
  not an error, so callers can `opts[:provider] || Config.cloud_provider()` unchanged.
  """
  @spec parse_provider(String.t() | nil) :: {:ok, atom() | nil} | {:error, ErrorMessage.t()}
  def parse_provider(nil), do: {:ok, nil}

  def parse_provider(value) when is_binary(value) do
    case Enum.find(providers(), &(Atom.to_string(&1) === value)) do
      nil ->
        {:error,
         ErrorMessage.bad_request("unknown provider #{inspect(value)} — known providers: #{inspect(providers())}", %{
           provider: value,
           known_providers: providers()
         })}

      provider ->
        {:ok, provider}
    end
  end

  @doc """
  SSH user for the active (or overridden) provider, resolved through its descriptor.

  Falls back to `"admin"` when the descriptor cannot be resolved (unregistered provider) or
  declares no default — the historical AWS default, so a lookup failure never blocks a task
  that otherwise ran fine before this accessor existed.
  """
  @spec ssh_user(keyword()) :: String.t()
  def ssh_user(opts \\ []) do
    case opts |> active_provider() |> fetch_descriptor() do
      {:ok, descriptor} -> descriptor.default_ssh_user() || "admin"
      {:error, _reason} -> "admin"
    end
  end

  @doc """
  Resource group / project tag namespace for the active (or overridden) provider.

  AWS reads its historical flat key; every other provider reads `:resource_group` from its
  own config namespace (`config :deploy_ex, <provider>, resource_group: ...`), which
  `validate_config/2` already validates against the descriptor's schema. Returns an error
  rather than `nil` when a real provider has not configured the key — see `provider_config_value/3`.
  """
  @spec resource_group(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}
  def resource_group(opts \\ []), do: provider_config_value(opts, :resource_group, &Config.aws_resource_group/0)

  @doc "Release bucket for the active (or overridden) provider, same resolution rule as `resource_group/1`."
  @spec release_bucket(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}
  def release_bucket(opts \\ []), do: provider_config_value(opts, :release_bucket, &Config.aws_release_bucket/0)

  # Routes through fetch_descriptor/1 rather than switching on active_provider(opts) directly
  # so a descriptor MODULE (the put_env-free test injection seam — same one capability/2 and
  # validate_config/2 already accept) resolves through the same registry key as its atom form.
  # Comparing the descriptor to DeployEx.Cloud.Providers.Aws (rather than the input atom to
  # :aws) makes that true for AWS too, not only for non-AWS providers.
  defp provider_config_value(opts, key, aws_reader) do
    case opts |> active_provider() |> fetch_descriptor() do
      {:ok, DeployEx.Cloud.Providers.Aws} ->
        {:ok, aws_reader.()}

      {:ok, descriptor} ->
        provider_setting_or_error(registry_key_for(descriptor), key)

      {:error, _reason} = error ->
        error
    end
  end

  defp registry_key_for(descriptor) do
    Enum.find_value(@providers, descriptor, fn {registry_key, mod} -> if mod === descriptor, do: registry_key end)
  end

  # A silent nil here would reach an object-store/CLI call as an empty container name (e.g.
  # OCI's `--bucket-name ''`) — fail loudly instead, matching OciObjectStore.require_compartment_id/1's
  # precedent of erroring on a missing config value rather than sending a malformed request.
  defp provider_setting_or_error(provider, key) do
    case Config.provider_setting(provider, key) do
      nil ->
        {:error,
         ErrorMessage.bad_request(
           "#{key} is required for #{inspect(provider)} (config :deploy_ex, #{inspect(provider)}, #{key}: \"...\")",
           %{provider: provider, key: key}
         )}

      value ->
        {:ok, value}
    end
  end

  defp invalid_config_error(provider, env) do
    {:error,
     ErrorMessage.bad_request("#{inspect(provider)} config must be a keyword list", %{
       provider: provider,
       config: env
     })}
  end

  defp fetch_descriptor(provider) when is_atom(provider) and not is_nil(provider) do
    case Map.fetch(@providers, provider) do
      {:ok, descriptor} -> {:ok, descriptor}
      :error -> fetch_descriptor_module(provider)
    end
  end

  defp fetch_descriptor(provider) do
    {:error,
     ErrorMessage.not_implemented(
       "cloud provider must be an atom, got #{inspect(provider)}",
       %{provider: provider, known_providers: Map.keys(@providers)}
     )}
  end

  defp fetch_descriptor_module(module) do
    if descriptor_module?(module) do
      {:ok, module}
    else
      {:error,
       ErrorMessage.not_implemented("cloud provider #{inspect(module)} is not implemented", %{
         provider: module,
         known_providers: Map.keys(@providers)
       })}
    end
  end

  defp descriptor_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :capabilities, 0) and
      function_exported?(module, :config_schema, 0)
  end

  defp fetch_capability(descriptor, capability) do
    case Map.fetch(descriptor.capabilities(), capability) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error,
         ErrorMessage.not_implemented(
           "#{capability} is not implemented for #{inspect(descriptor)}",
           %{capability: capability, provider: descriptor}
         )}
    end
  end

  defp validate_against_schema(descriptor, env, provider) do
    case NimbleOptions.validate(env, descriptor.config_schema()) do
      {:ok, _validated} ->
        :ok

      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error,
         ErrorMessage.bad_request("invalid #{inspect(provider)} config: #{Exception.message(error)}", %{
           provider: provider,
           key: error.key
         })}
    end
  end

  defp config_env(provider) do
    if provider === :aws do
      Application.get_all_env(:deploy_ex)
    else
      Application.get_env(:deploy_ex, provider) || []
    end
  end
end
