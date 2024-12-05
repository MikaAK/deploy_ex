defmodule Mix.Tasks.Terraform.ShowPassword do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Shows passwords for databases in the cluster"
  @moduledoc """
  Shows the password for databases within terraform

  ## Example
  ```bash
  mix terraform.show_password database_name
  ```
  """

  def run(args) do
    {opts, extra_args} = parse_args(args)
    directory = opts[:directory] || @terraform_default_path

    with :ok <- DeployExHelpers.check_in_umbrella(),
         database_name when not is_nil(database_name) <- List.first(extra_args) || show_database_selection(directory),
         {:ok, state} <- read_terraform_state(directory) do

      # Find the database module in the state
      case find_database_password(state, database_name) do
        {:ok, password} ->
          Mix.shell().info([:green, "Password for #{database_name}: ", :reset, password])
        :error ->
          Mix.raise("No password found for database: #{database_name}")
      end
    else
      nil -> Mix.raise("No database name provided")
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp read_terraform_state(directory) do
    state_path = Path.join(directory, "terraform.tfstate")
    backup_path = Path.join(directory, "terraform.tfstate.backup")

    cond do
      File.exists?(state_path) ->
        File.read!(state_path) |> Jason.decode()
      File.exists?(backup_path) ->
        File.read!(backup_path) |> Jason.decode()
      true ->
        {:error, "No terraform state file found"}
    end
  end

  defp find_database_password(state, database_name) do
    # Look for the random_password resource in the database module
    module_name = "module.rds_database[\"#{database_name}\"]"

    case get_in(state, ["resources"]) do
      resources when is_list(resources) ->
        Enum.find_value(resources, :error, fn resource ->
          if resource["module"] == module_name and
             resource["type"] == "random_password" and
             resource["name"] == "rds_database_password" do
            {:ok, get_in(resource, ["instances", Access.at(0), "attributes", "result"])}
          end
        end)
      _ ->
        :error
    end
  end

  defp show_database_selection(directory) do
    with {:ok, state} <- read_terraform_state(directory) do
      # Find all database modules in the state
      databases =
        state
        |> get_in(["resources"])
        |> Enum.filter(&String.starts_with?(&1["module"] || "", "module.rds_database"))
        |> Enum.map(fn resource ->
          resource["module"]
          |> String.replace(~r/module\.rds_database\["([^"]+)"\]/, "\\1")
        end)
        |> Enum.uniq()

      case databases do
        [] -> nil
        [single_db] -> single_db
        multiple_dbs ->
          [choice] = DeployExHelpers.prompt_for_choice(multiple_dbs)
          choice
      end
    else
      _ -> nil
    end
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
