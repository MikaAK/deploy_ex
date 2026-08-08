defmodule DeployEx.AwsBucket do
  @moduledoc """
  Region-first bucket helpers for the terraform state-bucket tasks.

  The S3 calls now live in `DeployEx.Cloud.S3ObjectStore`, which implements
  `DeployEx.Cloud.ObjectStore`. This module stays because its call sites pass the region as the
  FIRST argument, which the provider-neutral behaviour does not — it takes region in opts.
  """

  alias DeployEx.Cloud.S3ObjectStore

  @type bucket_res :: %{name: String.t(), creation_date: String.t()}

  @spec create_bucket(String.t()) :: ErrorMessage.t_res(any)
  @spec create_bucket(String.t(), String.t()) :: ErrorMessage.t_res(any)
  def create_bucket(region \\ DeployEx.Config.aws_region(), bucket_name) do
    S3ObjectStore.create_container(bucket_name, region: region)
  end

  @spec list_buckets() :: ErrorMessage.t_res(bucket_res)
  @spec list_buckets(String.t()) :: ErrorMessage.t_res(bucket_res)
  def list_buckets(region \\ DeployEx.Config.aws_region()) do
    S3ObjectStore.list_containers(region: region)
  end

  def list_objects(region \\ DeployEx.Config.aws_region(), bucket_name) do
    S3ObjectStore.list_objects(bucket_name, region: region)
  end

  @doc """
  Empties a bucket entirely.

  `all: true` is passed deliberately — the object store refuses an unscoped delete, and emptying
  the bucket is exactly what this function is for. Its only caller drops the terraform state
  bucket, whose name comes from config rather than an argument.
  """
  def delete_all_objects(region \\ DeployEx.Config.aws_region(), bucket_name, continuation_token \\ nil) do
    S3ObjectStore.delete_all_objects(bucket_name, [region: region, all: true], continuation_token)
  end

  def delete_bucket(region \\ DeployEx.Config.aws_region(), bucket_name) do
    S3ObjectStore.delete_container(bucket_name, region: region)
  end
end
