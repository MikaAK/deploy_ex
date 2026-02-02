defmodule DeployEx.TerraformState do
  @moduledoc """
  Handles reading Terraform state files and extracting values.
  """

  @terraform_state_filename "terraform.tfstate"

  @doc """
  Reads the Terraform state file and parses it into a map.

  ## Example:
      iex> DeployEx.TerraformState.read_state("/path/to/terraform")
      {:ok, %{"version" => 4, "resources" => [...], "outputs" => {...}}}
  """
  def read_state(directory) do
    state_path = Path.join(directory, @terraform_state_filename)

    if File.exists?(state_path) do
      case File.read!(state_path) |> Jason.decode() do
        {:ok, state} -> {:ok, state}
        error -> error
      end
    else
      {:error, "Terraform state file not found: #{state_path}"}
    end
  end

  @doc """
  Extracts a value from Terraform's "outputs" section.

  ## Example:
      iex> DeployEx.TerraformState.get_output(state, "databases.general.endpoint")
      {:ok, "survey-x-umbrella-db.cg0t38yjlqtp.us-west-2.rds.amazonaws.com:5432"}
  """
  def get_output(state, key_path) when is_binary(key_path) do
    case get_in(state, ["outputs"] ++ String.split(key_path, ".")) do
      nil -> {:error, "Output key not found: #{key_path}"}
      value -> {:ok, value}
    end
  end

  @doc """
  Extracts a specific attribute from a Terraform resource.

  ## Example:
      iex> DeployEx.TerraformState.get_resource_attribute(state, "aws_db_instance", "rds_database", "password")
      {:ok, "2LV5RBOEC62CQT6S"}
  """
  def get_resource_attribute(state, resource_type, resource_name, attribute) do
    case get_in(state, ["resources"]) do
      resources when is_list(resources) ->
        Enum.find_value(resources, {:error, "Resource not found"}, fn resource ->
          if resource["type"] == resource_type and resource["name"] == resource_name do
            get_in(resource, ["instances", Access.at(0), "attributes", attribute])
            |> case do
              nil -> {:error, "Attribute not found: #{attribute}"}
              value -> {:ok, value}
            end
          end
        end)

      _ -> {:error, "Invalid Terraform state format"}
    end
  end

  @doc """
  Extracts a specific attribute from a Terraform resource by matching a tag value.

  ## Example:
      iex> DeployEx.TerraformState.get_resource_attribute_by_tag(state, "aws_db_instance", "Name", "my-database", "password")
      {:ok, "2LV5RBOEC62CQT6S"}
  """
  def get_resource_attribute_by_tag(state, resource_type, tag_key, tag_value, attribute) do
    case get_in(state, ["resources"]) do
      resources when is_list(resources) ->
        Enum.find_value(resources, {:error, "Resource not found"}, fn resource ->
          if resource["type"] == resource_type do
            tags = get_in(resource, ["instances", Access.at(0), "attributes", "tags"]) || %{}
            if tags[tag_key] == tag_value do
              get_in(resource, ["instances", Access.at(0), "attributes", attribute])
              |> case do
                nil -> {:error, "Attribute not found: #{attribute}"}
                value -> {:ok, value}
              end
            end
          end
        end)

      _ -> {:error, "Invalid Terraform state format"}
    end
  end

  def get_app_display_name(app_name, opts \\ []) do
    terraform_dir = opts[:terraform_dir] || DeployEx.Config.terraform_folder_path()

    with {:ok, state} <- read_state(terraform_dir) do
      snake_app_name = String.replace(app_name, "-", "_")

      case find_instance_display_name(state, snake_app_name) do
        {:ok, name} -> {:ok, name}
        {:error, _} -> {:ok, default_display_name(app_name)}
      end
    else
      {:error, _} -> {:ok, default_display_name(app_name)}
    end
  end

  defp find_instance_display_name(state, app_name) do
    case get_in(state, ["resources"]) do
      resources when is_list(resources) ->
        result = Enum.find_value(resources, fn resource ->
          if resource["type"] === "aws_instance" and resource["module"] =~ app_name do
            instances = resource["instances"] || []
            Enum.find_value(instances, fn instance ->
              get_in(instance, ["attributes", "tags", "Name"])
            end)
          end
        end)

        case result do
          nil -> {:error, "Instance not found for app: #{app_name}"}
          name -> {:ok, extract_base_name(name)}
        end

      _ -> {:error, "Invalid Terraform state format"}
    end
  end

  defp extract_base_name(instance_name) do
    instance_name
    |> String.split("-")
    |> Enum.take_while(fn part -> not String.match?(part, ~r/^\d+$/) end)
    |> Enum.join("-")
    |> String.trim("-")
  end

  defp default_display_name(app_name) do
    app_name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
