defmodule DeployEx.Cloud.Infrastructure do
  @moduledoc """
  Network, image and key discovery needed to launch an instance ad-hoc.

  Every callback answers "what already exists in this account/tenancy that a new instance
  should attach to". Terraform owns CREATING these; this behaviour only reads them.
  """

  @callback find_network(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}

  @callback find_subnet(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}

  @callback find_key_pair(String.t(), keyword()) ::
              {:ok, String.t()} | {:error, ErrorMessage.t()}

  @callback find_image(keyword()) :: {:ok, String.t()} | {:error, ErrorMessage.t()}

  @doc "Identity the instance assumes so it can read releases and write state markers."
  @callback find_instance_identity(keyword()) ::
              {:ok, String.t() | nil} | {:error, ErrorMessage.t()}

  @doc """
  Composite convenience gathering every value above (plus a security group where the provider
  has one) in a single call, for callers that need the full set to launch an instance ad-hoc.

  Optional: today only the AWS adapter implements it (`DeployEx.AwsInfrastructure.gather_infrastructure/1`,
  a pre-existing public function this callback formalizes) — a provider without an
  ad-hoc-launch caller conforms without it.
  """
  @callback gather_infrastructure(keyword()) :: {:ok, map()} | {:error, ErrorMessage.t()}

  @optional_callbacks gather_infrastructure: 1
end
