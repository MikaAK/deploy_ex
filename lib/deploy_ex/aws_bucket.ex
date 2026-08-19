defmodule DeployEx.AwsBucket do
  alias ExAws.S3

  @type bucket_res :: %{name: String.t, creation_date: String.t}

  @spec create_bucket(String.t()) :: ErrorMessage.t_res(any)
  @spec create_bucket(String.t(), String.t()) :: ErrorMessage.t_res(any)
  def create_bucket(region \\ DeployEx.Config.aws_region(), bucket_name) do
    case ExAws.request(S3.put_bucket(bucket_name, region), region: region) do
      {:ok, _} -> :ok
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{bucket: bucket_name})}
    end
  end

  @spec list_buckets() :: ErrorMessage.t_res(bucket_res)
  @spec list_buckets(String.t()) :: ErrorMessage.t_res(bucket_res)
  def list_buckets(region \\ DeployEx.Config.aws_region()) do
    case ExAws.request(S3.list_buckets(), region: region) do
      {:ok, %{body: %{buckets: buckets}}} -> {:ok, buckets}
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{region: region})}
    end
  end

  def list_objects(region \\ DeployEx.Config.aws_region(), bucket_name) do
    case ExAws.request(S3.list_objects(bucket_name), region: region) do
      {:ok, _} = res -> res
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{region: region, bucket: bucket_name})}
    end
  end

  def delete_all_objects(region \\ DeployEx.Config.aws_region(), bucket_name, continuation_token \\ nil) do
    list_opts = if continuation_token, do: [continuation_token: continuation_token], else: []

    case ExAws.request(S3.list_objects_v2(bucket_name, list_opts), region: region) do
      {:ok, %{body: %{contents: objects, is_truncated: is_truncated, next_continuation_token: next_token}}} when objects !== [] ->
        object_keys = Enum.map(objects, & &1.key)

        case ExAws.request(S3.delete_multiple_objects(bucket_name, object_keys), region: region) do
          {:ok, _} ->
            if is_truncated do
              delete_all_objects(region, bucket_name, next_token)
            else
              :ok
            end
          {:error, {:http_error, code, message}} ->
            {:error, handle_error(code, message, %{region: region, bucket: bucket_name})}
        end

      {:ok, %{body: %{contents: [], is_truncated: is_truncated, next_continuation_token: next_token}}} ->
        if is_truncated do
          delete_all_objects(region, bucket_name, next_token)
        else
          :ok
        end

      {:ok, %{body: %{contents: objects}}} when objects !== [] ->
        object_keys = Enum.map(objects, & &1.key)

        case ExAws.request(S3.delete_multiple_objects(bucket_name, object_keys), region: region) do
          {:ok, _} -> :ok
          {:error, {:http_error, code, message}} ->
            {:error, handle_error(code, message, %{region: region, bucket: bucket_name})}
        end

      {:ok, _} -> :ok
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{region: region, bucket: bucket_name})}
    end
  end

  def delete_bucket(region \\ DeployEx.Config.aws_region(), bucket_name) do
    case ExAws.request(S3.delete_bucket(bucket_name), region: region) do
      {:ok, _} -> :ok
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{region: region, bucket: bucket_name})}
    end
  end

  defp handle_error(409, message, %{bucket: bucket_name}) do
    ErrorMessage.conflict("bucket already exists", %{bucket: bucket_name, message: message})
  end

  defp handle_error(404, message, %{bucket: bucket_name}) do
    ErrorMessage.not_found("bucket not found", %{bucket: bucket_name, message: message})
  end

  defp handle_error(code, message, %{region: region, bucket: bucket_name}) do
    %ErrorMessage{
      code: ErrorMessage.http_code_reason_atom(code),
      message: message,
      details: %{region: region, bucket: bucket_name}
    }
  end

  defp handle_error(code, message, %{region: region}) do
    %ErrorMessage{
      code: ErrorMessage.http_code_reason_atom(code),
      message: message,
      details: %{region: region}
    }
  end
end
