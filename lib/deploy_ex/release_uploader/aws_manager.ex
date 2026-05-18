defmodule DeployEx.ReleaseUploader.AwsManager do
  def get_releases(region, bucket, prefix \\ nil) do
    s3_opts = if prefix, do: [prefix: prefix], else: []

    fetch_paginated_keys(region, bucket, s3_opts, [])
  rescue
    e -> {:error, ErrorMessage.failed_dependency("failed to list S3 releases", %{error: Exception.message(e)})}
  end

  defp fetch_paginated_keys(region, bucket, s3_opts, acc) do
    bucket
      |> ExAws.S3.list_objects(s3_opts)
      |> ExAws.request(region: region)
      |> handle_list_response(region, bucket, s3_opts, acc)
  end

  defp handle_list_response(
         {:ok, %{body: %{contents: contents, is_truncated: "true"} = body}},
         region,
         bucket,
         s3_opts,
         acc
       ) do
    keys = Enum.map(contents, & &1.key)
    marker = next_marker(body, contents)

    fetch_paginated_keys(region, bucket, Keyword.put(s3_opts, :marker, marker), acc ++ keys)
  end

  defp handle_list_response({:ok, %{body: %{contents: contents}}}, _region, _bucket, _s3_opts, acc) do
    {:ok, acc ++ Enum.map(contents, & &1.key)}
  end

  defp handle_list_response({:error, reason}, _region, _bucket, _s3_opts, _acc) do
    {:error, ErrorMessage.failed_dependency("failed to list S3 releases", %{error: inspect(reason)})}
  end

  defp next_marker(%{next_marker: marker}, _contents) when is_binary(marker) and marker !== "", do: marker
  defp next_marker(_body, contents), do: contents |> List.last() |> Map.fetch!(:key)

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
