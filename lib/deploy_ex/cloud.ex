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
