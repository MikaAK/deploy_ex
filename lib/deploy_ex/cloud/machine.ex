defmodule DeployEx.Cloud.Machine do
  @moduledoc """
  Compute instance discovery and lifecycle.

  Tag filters are a LIST of `{key, matcher}` pairs, never a map. A map would collapse
  repeated keys and turn today's AND semantics on `--tag Env=a --tag Env=b` into
  "last one wins".

  A matcher is a scalar, a list of scalars, or a `Regex`. Only exact scalar and list
  matchers may be pushed down into a provider-native query; a regex is evaluated
  client-side against the decoded canonical tag map. Callers rely on the regex arm today
  because autoscaling-group instances carry composite tag values.
  """

  alias DeployEx.Cloud.Instance

  @typedoc "A single tag value to match against"
  @type scalar :: String.t() | boolean() | number()

  @typedoc "Exact scalar, any-of list, or a client-side evaluated pattern"
  @type matcher :: scalar() | [scalar()] | Regex.t()

  @typedoc "Canonical tag filters, AND-ed together"
  @type tag_filters :: [{String.t(), matcher()}]

  @callback find_instances_by_tags(tag_filters(), keyword()) ::
              {:ok, [Instance.t()]} | {:error, ErrorMessage.t()}

  @callback describe_instance(String.t(), keyword()) ::
              {:ok, Instance.t()} | {:error, ErrorMessage.t()}

  @callback start_instance(String.t(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback stop_instance(String.t(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback terminate_instance(String.t(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback run_instance(map(), keyword()) ::
              {:ok, Instance.t()} | {:error, ErrorMessage.t()}

  @doc "Preferred reachable address for an instance. IPv6 wins when present."
  @callback instance_address(Instance.t()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}

  @callback fetch_tags(String.t(), keyword()) ::
              {:ok, %{optional(String.t()) => String.t()}} | {:error, ErrorMessage.t()}

  @callback put_tags(String.t(), %{optional(String.t()) => String.t()}, keyword()) ::
              :ok | {:error, ErrorMessage.t()}

  @callback delete_tags(String.t(), [String.t()], keyword()) ::
              :ok | {:error, ErrorMessage.t()}
end
