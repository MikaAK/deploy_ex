defmodule DeployEx.ReleaseUploader.AwsManager do
  def get_releases(region, bucket, prefix \\ nil) do
    s3_opts = if prefix, do: [prefix: prefix], else: []

    keys = bucket
      |> ExAws.S3.list_objects(s3_opts)
      |> ExAws.stream!(region: region)
      |> Enum.map(& &1.key)

    {:ok, keys}
  rescue
    e -> {:error, ErrorMessage.failed_dependency("failed to list S3 releases", %{error: Exception.message(e)})}
  end

  def upload(file_path, region, bucket, upload_path) do
    file_path
      |> ExAws.S3.Upload.stream_file
      |> ExAws.S3.upload(bucket, upload_path)
      |> ExAws.request(region: region)
      |> handle_response
  end

  def tag_object(region, bucket, object_key, tags) do
    bucket
      |> ExAws.S3.put_object_tagging(object_key, tags)
      |> ExAws.request(region: region)
      |> handle_response
  end

  defp handle_response({:ok, %{body: body}}), do: {:ok, body}
  defp handle_response({:ok, :done}), do: :ok

  defp handle_response({:error, {:http_error, status, reason}}) do
    {:error, apply(ErrorMessage, ErrorMessage.http_code_reason_atom(status), ["aws failure", %{reason: reason}])}
    end

  defp handle_response({:error, error}) when is_binary(error) do
    {:error, ErrorMessage.failed_dependency("aws failure: #{error}")}
  end
end
