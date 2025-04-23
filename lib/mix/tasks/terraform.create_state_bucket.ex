defmodule Mix.Tasks.Terraform.CreateStateBucket do
  use Mix.Task

  alias DeployEx.AwsBucket

  @shortdoc "Creates a bucket within S3 to host the terraform state file"
  @moduledoc """
  Creates a bucket within S3 to host the terraform state file.
  This file needs to be run before anythign else

  ## Example
  ```bash
  mix terraform.create_state_bucket
  ```
  """

  def run(_args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    # {opts, extra_args} = parse_args(args)
    # opts = Keyword.put_new(opts, :directory, @terraform_default_path)
    # {machine_opts, opts} = Keyword.split(opts, [:resource_group])

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, buckets} <- AwsBucket.list_buckets() do
      bucket = DeployEx.Config.aws_release_state_bucket()
      region = DeployEx.Config.aws_region()

      if bucket in Enum.map(buckets, &(&1.name)) do
        Mix.shell().info([
          :yellow, "No need to create bucket ",
          :yellow, :bright, bucket, :reset, :yellow,
          " since it already exists in ", :bright, region, :reset, :yellow, "!"
        ])

        :ok
      else
        case DeployEx.AwsBucket.create_bucket(region, bucket) do
          {:error, error} -> Mix.raise(to_string(error))

          :ok ->
            Mix.shell().info([
              :green, "Successfully created bucket ", :green,
              :bright, bucket, :reset, :green,
              " created in ", :bright, region, :reset
            ])
        end
      end
    else
      {:error, error} -> Mix.raise(to_string(error))
    end
  end
end
