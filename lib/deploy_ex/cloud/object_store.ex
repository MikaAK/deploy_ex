defmodule DeployEx.Cloud.ObjectStore do
  @moduledoc """
  Blob storage. Deliberately not an S3 interface.

  S3-compatible storage is the first implementation, not the contract. Azure Blob has no
  S3-compatible API, so nothing here names buckets-as-S3, ETags, or multipart uploads.

  `put_object_tags/4` is OPTIONAL. Providers without native object tagging inherit a
  portable default rather than being blocked.
  """

  @type key :: String.t()
  @type container :: String.t()

  @callback get_object(container(), key(), keyword()) ::
              {:ok, binary()} | {:error, ErrorMessage.t()}

  @callback put_object(container(), key(), binary(), keyword()) ::
              :ok | {:error, ErrorMessage.t()}

  @callback delete_object(container(), key(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @doc "Lists keys under a prefix, following pagination to completion."
  @callback list_objects(container(), keyword()) ::
              {:ok, [key()]} | {:error, ErrorMessage.t()}

  @callback upload_file(container(), key(), Path.t(), keyword()) ::
              :ok | {:error, ErrorMessage.t()}

  @callback put_object_tags(container(), key(), %{optional(String.t()) => String.t()}, keyword()) ::
              :ok | {:error, ErrorMessage.t()}

  @callback create_container(container(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback delete_container(container(), keyword()) :: :ok | {:error, ErrorMessage.t()}

  @callback list_containers(keyword()) :: {:ok, [container()]} | {:error, ErrorMessage.t()}

  @optional_callbacks put_object_tags: 4
end
