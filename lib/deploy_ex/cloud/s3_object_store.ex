defmodule DeployEx.Cloud.S3ObjectStore do
  @moduledoc """
  S3-backed implementation of `DeployEx.Cloud.ObjectStore`.

  This is implementation #1 of the object-store contract, not the contract itself. OCI and
  Google both expose S3-compatible endpoints, so they can reuse this module by pointing ExAws
  at their host; Azure Blob has no S3 API and needs its own implementation behind the same
  behaviour.

  `region` in opts, defaulting to `DeployEx.Config.aws_region/0`, is the only AWS-shaped
  detail here, and ExAws needs it on every request.
  """

  @behaviour DeployEx.Cloud.ObjectStore

  alias ExAws.S3

  @impl DeployEx.Cloud.ObjectStore
  def get_object(container, key, opts \\ []) do
    container
    |> S3.get_object(key)
    |> run(opts, %{container: container, key: key})
    |> unwrap_body()
  end

  @impl DeployEx.Cloud.ObjectStore
  def put_object(container, key, body, opts \\ []) do
    container
    |> S3.put_object(key, body)
    |> run(opts, %{container: container, key: key})
    |> discard_body()
  end

  @impl DeployEx.Cloud.ObjectStore
  def delete_object(container, key, opts \\ []) do
    container
    |> S3.delete_object(key)
    |> run(opts, %{container: container, key: key})
    |> discard_body()
  end

  @impl DeployEx.Cloud.ObjectStore
  def list_objects(container, opts \\ []) do
    {request_opts, opts} = Keyword.split(opts, [:prefix, :marker, :max_keys])

    container
    |> S3.list_objects(request_opts)
    |> run(opts, %{container: container})
    |> extract_keys()
  end

  @impl DeployEx.Cloud.ObjectStore
  def upload_file(container, key, path, opts \\ []) do
    path
    |> S3.Upload.stream_file()
    |> S3.upload(container, key)
    |> run(opts, %{container: container, key: key, path: path})
    |> discard_body()
  end

  @impl DeployEx.Cloud.ObjectStore
  def put_object_tags(container, key, tags, opts \\ []) do
    container
    |> S3.put_object_tagging(key, tags)
    |> run(opts, %{container: container, key: key})
    |> discard_body()
  end

  @impl DeployEx.Cloud.ObjectStore
  def create_container(container, opts \\ []) do
    region = region(opts)

    container
    |> S3.put_bucket(region)
    |> run(opts, %{container: container})
    |> discard_body()
  end

  @impl DeployEx.Cloud.ObjectStore
  def delete_container(container, opts \\ []) do
    container
    |> S3.delete_bucket()
    |> run(opts, %{container: container})
    |> discard_body()
  end

  @impl DeployEx.Cloud.ObjectStore
  def list_containers(opts \\ []) do
    case run(S3.list_buckets(), opts, %{region: region(opts)}) do
      {:ok, %{body: %{buckets: buckets}}} -> {:ok, buckets}
      {:error, _} = error -> error
    end
  end

  @doc """
  Empties a container, following pagination to completion.

  Not a behaviour callback — it is a convenience built on the S3 bulk-delete API, which has no
  portable equivalent. A provider without bulk delete would loop `delete_object/3`.
  """
  def delete_all_objects(container, opts \\ [], continuation_token \\ nil) do
    list_opts = if continuation_token, do: [continuation_token: continuation_token], else: []

    case run(S3.list_objects_v2(container, list_opts), opts, %{container: container}) do
      {:ok, %{body: body}} -> delete_listed_objects(container, body, opts)
      {:error, _} = error -> error
    end
  end

  @doc """
  Maps an S3 error status onto an `ErrorMessage`.

  Public because it is the only part of this module that needs no live account.
  """
  def classify_error(409, message, details) do
    {:error, ErrorMessage.conflict("container already exists", Map.put(details, :message, message))}
  end

  def classify_error(404, message, details) do
    {:error, ErrorMessage.not_found("object or container not found", Map.put(details, :message, message))}
  end

  def classify_error(status_code, message, details) do
    {:error,
     %ErrorMessage{
       code: ErrorMessage.http_code_reason_atom(status_code),
       message: to_string(message),
       details: details
     }}
  end

  defp delete_listed_objects(container, body, opts) do
    keys = body |> Map.get(:contents, []) |> Enum.map(& &1.key)
    truncated? = Map.get(body, :is_truncated, false)
    next_token = Map.get(body, :next_continuation_token)

    with :ok <- delete_batch(container, keys, opts) do
      if truncated? do
        delete_all_objects(container, opts, next_token)
      else
        :ok
      end
    end
  end

  defp delete_batch(_container, [], _opts), do: :ok

  defp delete_batch(container, keys, opts) do
    container
    |> S3.delete_multiple_objects(keys)
    |> run(opts, %{container: container})
    |> discard_body()
  end

  defp run(request, opts, details) do
    case ExAws.request(request, region: region(opts)) do
      {:ok, _} = success -> success
      {:error, {:http_error, status_code, %{body: body}}} -> classify_error(status_code, body, details)
      {:error, {:http_error, status_code, message}} -> classify_error(status_code, message, details)
    end
  end

  defp region(opts), do: opts[:region] || DeployEx.Config.aws_region()

  defp unwrap_body({:ok, %{body: body}}), do: {:ok, body}
  defp unwrap_body({:error, _} = error), do: error

  defp discard_body({:ok, _}), do: :ok
  defp discard_body({:error, _} = error), do: error

  defp extract_keys({:ok, %{body: %{contents: contents}}}), do: {:ok, Enum.map(contents, & &1.key)}
  defp extract_keys({:ok, _}), do: {:ok, []}
  defp extract_keys({:error, _} = error), do: error
end
