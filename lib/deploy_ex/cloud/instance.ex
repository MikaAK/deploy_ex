defmodule DeployEx.Cloud.Instance do
  @moduledoc """
  Provider-neutral description of a single compute instance.

  Deliberately does NOT derive `Jason.Encoder`. The `--format json` output of
  `mix deploy_ex.find_nodes` is a frozen user-visible contract whose key set differs from
  these field names, so the mapping is written explicitly at the output site rather than
  falling out of a derive.
  """

  defstruct [
    :id,
    :ipv6,
    :launched_at,
    :name,
    :private_ip,
    :public_ip,
    :qa_node?,
    :state,
    :tags,
    :type
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          ipv6: String.t() | nil,
          launched_at: DateTime.t() | String.t() | nil,
          name: String.t() | nil,
          private_ip: String.t() | nil,
          public_ip: String.t() | nil,
          qa_node?: boolean() | nil,
          state: atom() | String.t() | nil,
          tags: %{optional(String.t()) => String.t()} | nil,
          type: String.t() | nil
        }
end
