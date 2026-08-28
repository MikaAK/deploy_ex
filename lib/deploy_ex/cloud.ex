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
  `validate_config/2` already validates against the descriptor's schema.
  """
  @spec resource_group(keyword()) :: String.t() | nil
  def resource_group(opts \\ []), do: provider_config_value(opts, :resource_group, &Config.aws_resource_group/0)

  @doc "Release bucket for the active (or overridden) provider, same resolution rule as `resource_group/1`."
  @spec release_bucket(keyword()) :: String.t() | nil
  def release_bucket(opts \\ []), do: provider_config_value(opts, :release_bucket, &Config.aws_release_bucket/0)

  defp provider_config_value(opts, key, aws_reader) do
    case active_provider(opts) do
      :aws -> aws_reader.()
      provider when is_atom(provider) -> Application.get_env(:deploy_ex, provider, [])[key]
      _non_atom -> nil
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
