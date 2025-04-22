defmodule DeployEx.AwsBucket do
  alias ExAws.S3

  def create_bucket(region \\ DeployEx.Config.aws_region(), bucket_name) do
    case ExAws.request(S3.put_bucket(region, bucket_name), region: region) do
      {:ok, _} = res -> res
      {:error, msg} ->
        if msg =~ "Not Found" do
          {:error, ErrorMessage.not_found("bucket doesn't exist")}
        else
          {:error, ErrorMessage.failed_dependency("error")}
        end
    end
  end

  def list_buckets(region \\ DeployEx.Config.aws_region()) do
    case ExAws.request(S3.list_buckets(), region: region) do
      {:ok, _} = res -> res
      {:error, msg} ->
        if msg =~ "Not Found" do
          {:error, ErrorMessage.not_found("bucket doesn't exist")}
        else
          {:error, ErrorMessage.failed_dependency("error")}
        end
    end
  end

  def list_objects(region \\ DeployEx.Config.aws_region(), bucket_name) do
    case ExAws.request(S3.list_objects(bucket_name), region: region) do
      {:ok, _} = res -> res
      {:error, msg} ->
        if msg =~ "Not Found" do
          {:error, ErrorMessage.not_found("bucket doesn't exist")}
        else
          {:error, ErrorMessage.failed_dependency("error")}
        end
    end
  end
end
