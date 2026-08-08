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
    {request_opts, request_config} = Keyword.split(opts, [:prefix, :marker, :max_keys])

    list_objects_page(container, request_opts, request_config, [])
  end

  # S3 caps a list response at 1000 keys and signals more with is_truncated, so a single
  # request silently truncates. The release bucket holds thousands of objects, and a
  # truncated listing reads as "these are all the releases" rather than as an error.
  defp list_objects_page(container, request_opts, request_config, acc) do
    response =
      container
      |> S3.list_objects(request_opts)
      |> run(request_config, %{container: container})

    case response do
      {:ok, %{body: body}} ->
        keys = body |> Map.get(:contents, []) |> Enum.map(& &1.key)
        accumulated = acc ++ keys

        if truncated?(body) and not Enum.empty?(keys) do
          next_opts = Keyword.put(request_opts, :marker, next_marker(body, keys))

          list_objects_page(container, next_opts, request_config, accumulated)
        else
          {:ok, accumulated}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp truncated?(body), do: Map.get(body, :is_truncated) in [true, "true"]

  defp next_marker(body, keys) do
    case Map.get(body, :next_marker) do
      marker when is_binary(marker) and marker !== "" -> marker
      _absent -> List.last(keys)
    end
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
  Deletes objects in a container, following pagination to completion.

  Not a behaviour callback — it is built on the S3 bulk-delete API, which has no portable
  equivalent. A provider without bulk delete would loop `delete_object/3`.

  **Scope is mandatory and explicit.** Pass either `prefix: "some/path"` to delete a subtree, or
  `all: true` to empty the whole container. Calling it with neither raises rather than deleting
  everything, because the earlier signature accepted `prefix:` and silently ignored it — a call
  that read as narrowly scoped emptied an entire production bucket.
  """
  def delete_all_objects(container, opts \\ [], continuation_token \\ nil) do
    scope = delete_scope!(container, opts)
    list_opts = scope ++ continuation_opts(continuation_token)

    case run(S3.list_objects_v2(container, list_opts), opts, %{container: container}) do
      {:ok, %{body: body}} -> delete_listed_objects(container, body, opts)
      {:error, _reason} = error -> error
    end
  end

  defp delete_scope!(container, opts) do
    prefix = opts[:prefix]

    cond do
      is_binary(prefix) and prefix !== "" -> [prefix: prefix]
      opts[:all] === true -> []
      true -> raise ArgumentError, unscoped_delete_message(container)
    end
  end

  defp unscoped_delete_message(container) do
    "refusing to delete every object in #{inspect(container)} without an explicit scope — " <>
      "pass prefix: \"...\" to delete a subtree, or all: true to empty the container"
  end

  defp continuation_opts(token) do
    if present?(token), do: [continuation_token: token], else: []
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
    next_token = Map.get(body, :next_continuation_token)

    with :ok <- delete_batch(container, keys, opts) do
      if truncated?(body) and present?(next_token) do
        delete_all_objects(container, opts, next_token)
      else
        :ok
      end
    end
  end

  # ExAws returns is_truncated as the STRING "false", which is truthy in Elixir — branching on it
  # directly recurses forever, and the empty next_continuation_token then makes S3 reject the
  # request. Compare against known values instead of relying on truthiness.
  defp present?(value), do: is_binary(value) and value !== ""

  defp delete_batch(_container, [], _opts), do: :ok

  defp delete_batch(container, keys, opts) do
    container
    |> S3.delete_multiple_objects(keys)
    |> run(opts, %{container: container})
    |> discard_body()
  end

  # `:request_fn` is the injection seam that makes pagination testable. Without it every
  # page-boundary case needs a live account, which is why the paginators originally shipped with
  # source-grep pins instead of tests — and a source grep cannot fail when the loop is removed.
  # Same dependency-injection style as ProjectContext.check_valid_project/1.
  defp run(request, opts, details) do
    request_fn = opts[:request_fn] || (&ExAws.request/2)

    case request_fn.(request, region: region(opts)) do
      {:ok, _} = success -> success
      {:error, {:http_error, status_code, %{body: body}}} -> classify_error(status_code, body, details)
      {:error, {:http_error, status_code, message}} -> classify_error(status_code, message, details)
      {:error, reason} -> {:error, ErrorMessage.failed_dependency(describe_reason(reason), details)}
    end
  end

  # Credential lookup and socket failures come back as a bare term with no status to classify;
  # without this clause they raise a CaseClauseError instead of surfacing as an error tuple.
  defp describe_reason(reason) when is_binary(reason), do: reason
  defp describe_reason(reason), do: inspect(reason)

  defp region(opts), do: opts[:region] || DeployEx.Config.aws_region()

  defp unwrap_body({:ok, %{body: body}}), do: {:ok, body}
  defp unwrap_body({:error, _} = error), do: error

  defp discard_body({:ok, _}), do: :ok
  defp discard_body({:error, _} = error), do: error

end
