defmodule DeployEx.Cloud.PrivFileSet do
  @moduledoc """
  Selects which `priv/` templates belong to a provider.

  Every non-AWS provider lives under a `providers/<name>/` directory. AWS is the complement —
  everything NOT under a `providers/` directory — expressed as one rule so adding a provider
  never requires rewording it.

  Non-AWS files FLATTEN on the way out: `providers/oci/network.tf.eex` renders to `network.tf`
  at the terraform root, because tofu only loads root-level `.tf` and runs in the configured
  terraform folder.

  The `providers` predicate is a path-COMPONENT test, never a substring match — an AWS tree
  legitimately contains a rendered `providers.tf` at its root, and a prefix match would
  misclassify it as provider-scoped and drop it from the AWS set.
  """

  @providers_dir "providers"

  @doc """
  Source/destination pairs for `provider`, relative to the given priv subdirectory.

  Returns `{:ok, [{source_relative, dest_relative}]}`, or an error when the provider has no
  files of its own — which is how an unimplemented provider surfaces rather than silently
  seeding an empty tree.
  """
  @spec files(atom(), Path.t()) :: {:ok, [{Path.t(), Path.t()}]} | {:error, ErrorMessage.t()}
  def files(provider, priv_path) do
    case provider_relative_paths(provider, priv_path) do
      [] ->
        {:error,
         ErrorMessage.not_implemented("no #{provider} templates exist in #{priv_path}", %{
           provider: provider,
           priv_path: priv_path
         })}

      paths ->
        {:ok, paths}
    end
  end

  @doc "True when `relative_path` belongs to `provider`'s file set."
  @spec member?(atom(), Path.t()) :: boolean()
  def member?(:aws, relative_path), do: not provider_scoped?(relative_path)

  def member?(provider, relative_path) do
    case Path.split(relative_path) do
      [@providers_dir, name | _rest] -> name === to_string(provider)
      _not_scoped -> false
    end
  end

  @doc """
  Destination for a source path under `provider`.

  AWS keeps its layout. Everything else drops the `providers/<name>/` prefix so the file lands
  where tofu and ansible actually look for it.
  """
  @spec destination(atom(), Path.t()) :: Path.t()
  def destination(:aws, relative_path), do: relative_path

  def destination(provider, relative_path) do
    case Path.split(relative_path) do
      [@providers_dir, name | rest] when rest !== [] ->
        if name === to_string(provider), do: Path.join(rest), else: relative_path

      _not_scoped ->
        relative_path
    end
  end

  defp provider_relative_paths(provider, priv_path) do
    priv_path
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, priv_path))
    |> Enum.filter(&member?(provider, &1))
    |> Enum.map(&{&1, destination(provider, &1)})
  end

  defp provider_scoped?(relative_path) do
    @providers_dir in (relative_path |> Path.split() |> Enum.drop(-1))
  end
end
