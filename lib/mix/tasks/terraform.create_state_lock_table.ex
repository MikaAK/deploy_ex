defmodule Mix.Tasks.Terraform.CreateStateLockTable do
  use Mix.Task

  alias DeployEx.AwsDynamodb

  @shortdoc "Creates a DynamoDB table for Terraform state locking"
  @moduledoc """
  Creates a DynamoDB table for Terraform state locking.
  This table is used to prevent concurrent Terraform operations.

  ## Example
  ```bash
  mix terraform.create_state_lock_table
  ```
  """

  def run(_args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, tables} <- AwsDynamodb.list_tables() do
      table_name = DeployEx.Config.aws_release_state_lock_table()
      region = DeployEx.Config.aws_region()

      if table_name in tables do
        Mix.shell().info([
          :yellow, "No need to create table ",
          :yellow, :bright, table_name, :reset, :yellow,
          " since it already exists in ", :bright, region, :reset, :yellow, "!"
        ])

        :ok
      else
        case DeployEx.AwsDynamodb.create_table(region, table_name, "LockID", :string) do
          {:error, error} -> Mix.raise(to_string(error))

          :ok ->
            Mix.shell().info([
              :green, "Successfully created DynamoDB table ", :green,
              :bright, table_name, :reset, :green,
              " created in ", :bright, region, :reset
            ])
        end
      end
    else
      {:error, error} -> Mix.raise(to_string(error))
    end
  end
end
