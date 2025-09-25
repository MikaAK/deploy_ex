defmodule Mix.Tasks.Terraform.DropStateBucket do
  use Mix.Task

  alias DeployEx.AwsBucket

  @shortdoc "Drops the S3 bucket used to host the Terraform state file"
  @moduledoc """
  Drops the S3 bucket used to host the Terraform state file.

  ## Example
  ```bash
  mix terraform.drop_state_bucket
  ```
  """

  def run(_args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, buckets} <- AwsBucket.list_buckets() do
      bucket = DeployEx.Config.aws_release_state_bucket()
      region = DeployEx.Config.aws_region()

      if bucket in Enum.map(buckets, &(&1.name)) do
        with :ok <- DeployEx.AwsBucket.delete_all_objects(region, bucket),
             :ok <- DeployEx.AwsBucket.delete_bucket(region, bucket) do
          Mix.shell().info([
            :green, "Successfully deleted bucket ",
            :green, :bright, bucket, :reset, :green,
            " from ", :bright, region, :reset, :green, "!"
          ])
          :ok
        else
          {:error, error} -> Mix.raise(to_string(error))
        end
      else
        Mix.shell().info([
          :yellow, "No need to drop bucket ",
          :yellow, :bright, bucket, :reset, :yellow,
          " since it does not exist in ", :bright, region, :reset, :yellow, "!"
        ])
        :ok
      end
    else
      {:error, error} -> Mix.raise(to_string(error))
    end
  end
end
