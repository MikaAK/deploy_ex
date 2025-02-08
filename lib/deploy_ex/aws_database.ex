defmodule DeployEx.AwsDatabase do
  @moduledoc """
  Module for interacting with AWS RDS databases.
  """

  import SweetXml, only: [sigil_x: 2]

  def fetch_aws_databases do
    case ExAws.request(ExAws.RDS.describe_db_instances(), region: DeployEx.Config.aws_region()) do
      {:ok, %{body: body}} ->
        instances = body
          |> SweetXml.xpath(~x"//DBInstances/DBInstance"l,
            identifier: ~x"./DBInstanceIdentifier/text()"s,
            endpoint: [
              ~x"./Endpoint",
              host: ~x"./Address/text()"s,
              port: ~x"./Port/text()"i
            ],
            username: ~x"./MasterUsername/text()"s,
            database: ~x"./DBName/text()"s,
            tags: [
              ~x"./TagList/Tag"l,
              key: ~x"./Key/text()"s,
              value: ~x"./Value/text()"s
            ]
          )
        {:ok, instances}

      {:error, {"AccessDenied", message}} ->
        {:error, ErrorMessage.unauthorized("AWS RDS access denied", %{message: message})}

      {:error, {"InvalidClientTokenId", message}} ->
        {:error, ErrorMessage.unauthorized("Invalid AWS credentials", %{message: message})}

      {:error, {error_type, message}} ->
        {:error, ErrorMessage.failed_dependency("AWS RDS API error: #{error_type}", %{message: message})}

      {:error, error} ->
        {:error, ErrorMessage.internal_server_error("Failed to fetch RDS instances", %{error: error})}
    end
  end

  def fetch_aws_databases_by_identifier(identifier) do
    with {:ok, instances} <- fetch_aws_databases() do
      case Enum.find(instances, fn instance -> instance.identifier == identifier end) do
        nil -> {:error, ErrorMessage.not_found("Database with identifier #{identifier} not found")}
        instance -> {:ok, [format_instance(instance)]}
      end
    end
  end

  def fetch_aws_databases_by_tag(key, value) do
    with {:ok, instances} <- fetch_aws_databases() do
      filtered_dbs = instances
        |> Enum.to_list() |> IO.inspect()
        |> Stream.filter(fn instance ->
          Enum.any?(instance.tags, fn
            %{key: ^key, value: ^value} -> true
            _ -> false
          end)
        end)
        |> Enum.map(&format_instance/1)

      case filtered_dbs do
        [] -> {:error, ErrorMessage.not_found("No databases found with #{key}=#{value} in ")}
        dbs -> {:ok, dbs}
      end
    end
  end

  defp format_instance(instance) do
    %{
      name: get_name_tag(instance),
      endpoint: "#{instance.endpoint.host}:#{instance.endpoint.port}",
      port: instance.endpoint.port,
      username: instance.username,
      database: instance.database
    }
  end

  defp get_name_tag(db) do
    Enum.find_value(db.tags, db.identifier, fn
      %{key: "Name", value: value} -> value
      _ -> false
    end)
  end
end
