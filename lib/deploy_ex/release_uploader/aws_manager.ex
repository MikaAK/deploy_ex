defmodule DeployEx.ReleaseUploader.AwsManager do
  @moduledoc """
  Release-bucket operations, resolved through the active provider's object store.

  Every function here was 100% S3 plumbing with no release-specific logic — `get_releases/3`,
  `upload/4` and `tag_object/4` map exactly onto `list_objects/2`, `upload_file/4` and
  `put_object_tags/4` on `DeployEx.Cloud.ObjectStore`. A per-provider release manager would
  have been a second abstraction over the same three operations, so the provider seam lives in
  the object store and this module only adapts the argument order.

  The name is historical: its callers pass region first, which the provider-neutral behaviour
  does not, and renaming it would touch call sites unrelated to making a second provider work.
  """

  alias DeployEx.Cloud

  @spec get_releases(String.t() | nil, String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, ErrorMessage.t()}
  def get_releases(region, bucket, prefix \\ nil) do
    with {:ok, store} <- Cloud.capability(:object_store) do
      store.list_objects(bucket, store_opts(region, prefix: prefix))
    end
  rescue
    e ->
      {:error,
       ErrorMessage.failed_dependency("failed to list releases", %{
         exception: inspect(e.__struct__),
         error: Exception.message(e),
         stacktrace: Exception.format_stacktrace(__STACKTRACE__)
       })}
  end

  @spec upload(Path.t(), String.t() | nil, String.t(), String.t()) ::
          :ok | {:error, ErrorMessage.t()}
  def upload(file_path, region, bucket, upload_path) do
    with {:ok, store} <- Cloud.capability(:object_store) do
      store.upload_file(bucket, upload_path, file_path, store_opts(region))
    end
  end

  @spec tag_object(String.t() | nil, String.t(), String.t(), map()) ::
          :ok | {:error, ErrorMessage.t()}
  def tag_object(region, bucket, object_key, tags) do
    with {:ok, store} <- Cloud.capability(:object_store) do
      store.put_object_tags(bucket, object_key, tags, store_opts(region))
    end
  end

  defp store_opts(region, extra \\ []) do
    extra
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.merge(region_opts(region))
  end

  defp region_opts(nil), do: []
  defp region_opts(region), do: [region: region]
end
