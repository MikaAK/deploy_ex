defmodule DeployEx.Cloud.Security do
  @moduledoc """
  Ingress rules for an instance or group of instances.

  Named for the CONCEPT rather than any provider's object. AWS has security groups, OCI
  has network security groups, GCP has no per-instance construct at all and expresses the
  same intent as VPC firewall rules selected by network tag. The callbacks take a group
  identifier and a CIDR so all three can implement them.
  """

  @callback find_group(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}

  @callback authorize_ingress(String.t(), String.t(), keyword()) ::
              :ok | {:error, ErrorMessage.t()}

  @callback revoke_ingress(String.t(), String.t(), keyword()) ::
              :ok | {:error, ErrorMessage.t()}

  @callback list_ingress(String.t(), keyword()) ::
              {:ok, [map()]} | {:error, ErrorMessage.t()}
end
