defmodule Mix.Tasks.Terraform.ShowPassword do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Shows passwords for databases in the cluster"
  @moduledoc """
  Shows the password for databases within Terraform.

  ## Example:
  ```bash
  mix terraform.show_password database_name
  ```
  """

  def run(args) do
    {opts, extra_args} = parse_args(args)
    directory = opts[:directory] || @terraform_default_path

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, state} <- DeployEx.TerraformState.read_state(directory),
         database_name when not is_nil(database_name) <- List.first(extra_args) || show_database_selection(state),
         {:ok, password} <- DeployEx.TerraformState.get_resource_attribute_by_tag(
           state,
           "aws_db_instance",
           "Name",
           database_name,
           "password"
         ) do
      Mix.shell().info([:green, "Password for #{database_name}: ", :reset, password])
    else
      nil -> Mix.raise("No database name provided")
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp show_database_selection(state) do
    case get_databases_from_state(state) do
      [] -> nil
      [single_db] -> single_db
      multiple_dbs ->
        [choice] = DeployExHelpers.prompt_for_choice(multiple_dbs)
        choice
    end
  end

  defp get_databases_from_state(state) do
    state["resources"]
    |> Enum.filter(&(&1["type"] == "aws_db_instance"))
    |> Enum.flat_map(fn resource ->
      case get_in(resource, ["instances", Access.at(0), "attributes", "tags"]) do
        tags when is_map(tags) -> [tags["Name"]]
        _ -> []
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [q: :quiet, d: :directory],
      switches: [
        directory: :string,
        quiet: :boolean
      ]
    )
  end
end
