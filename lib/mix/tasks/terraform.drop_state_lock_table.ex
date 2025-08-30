defmodule Mix.Tasks.Terraform.DropStateLockTable do
  use Mix.Task

  alias DeployEx.AwsDynamodb

  @shortdoc "Drops the DynamoDB table used for Terraform state locking"
  @moduledoc """
  Drops the DynamoDB table used for Terraform state locking.
  This will remove the table that prevents concurrent Terraform operations.

  ## Example
  ```bash
  mix terraform.drop_state_lock_table
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
        case DeployEx.AwsDynamodb.delete_table(region, table_name) do
          {:error, error} -> Mix.raise(to_string(error))

          :ok ->
            Mix.shell().info([
              :green, "Successfully deleted DynamoDB table ", :green,
              :bright, table_name, :reset, :green,
              " from ", :bright, region, :reset
            ])
        end
      else
        Mix.shell().info([
          :yellow, "Table ",
          :yellow, :bright, table_name, :reset, :yellow,
          " does not exist in ", :bright, region, :reset, :yellow, "!"
        ])

        :ok
      end
    else
      {:error, error} -> Mix.raise(to_string(error))
    end
  end
end
