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
        {:error, handle_error(code, message, %{bucket: bucket_name})}
    end
  end

  def list_objects(region \\ DeployEx.Config.aws_region(), bucket_name) do
    case ExAws.request(S3.list_objects(bucket_name), region: region) do
      {:ok, _} = res -> res
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{bucket: bucket_name})}
    end
  end

  def delete_bucket(region \\ DeployEx.Config.aws_region(), bucket_name) do
    case ExAws.request(S3.delete_bucket(bucket_name), region: region) do
      {:ok, _} -> :ok
      {:error, {:http_error, code, message}} ->
        {:error, handle_error(code, message, %{bucket: bucket_name})}
    end
  end

  defp handle_error(409, message, %{bucket: bucket_name}) do
    ErrorMessage.conflict("bucket already exists", %{bucket: bucket_name, message: message})
  end

  defp handle_error(404, message, %{bucket: bucket_name}) do
    ErrorMessage.not_found("bucket not found", %{bucket: bucket_name, message: message})
  end

  defp handle_error(code, message, %{bucket: bucket_name}) do
    %ErrorMessage{
      code: ErrorMessage.http_code_reason_atom(code),
      message: message,
      details: %{bucket: bucket_name}
    }
  end
end
