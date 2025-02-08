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
end
