defmodule DeployEx.ReleaseUploader.AwsManager do
  def get_releases(region, bucket) do
    res = bucket |> ExAws.S3.list_objects |> ExAws.request(region: region) |> handle_response

    with {:ok, %{contents: contents}} <- res do
      {:ok, Enum.map(contents, &(&1.key))}
    end
  end

  def upload(file_path, region, bucket, upload_path) do
    file_path
      |> ExAws.S3.Upload.stream_file
      |> ExAws.S3.upload(bucket, upload_path)
      |> ExAws.request(reigon: region)
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
