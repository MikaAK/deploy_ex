defmodule DeployEx.AwsDatabase do
  @moduledoc """
  Module for interacting with AWS RDS databases.
  """

  import SweetXml, only: [sigil_x: 2]

  @doc """
  Every RDS instance in the region, following pagination to completion.

  DescribeDBInstances caps a response (default 100) and signals more via `Marker`. A single
  request therefore truncates silently on a large account — it returns `{:ok, partial}`, not an
  error — same class of bug already fixed in `AwsAutoscaling.fetch_all_asgs/5`.
  """
  def fetch_aws_databases(opts \\ []) do
    fetch_databases_page(opts, [])
  end

  defp fetch_databases_page(opts, acc) do
    {request_fn, describe_opts} = Keyword.pop(opts, :request_fn, &ExAws.request/2)

    response =
      describe_opts
      |> ExAws.RDS.describe_db_instances()
      |> request_fn.(region: DeployEx.Config.aws_region())

    case response do
      {:ok, %{body: body}} ->
        accumulated = acc ++ extract_instances(body)

        case extract_marker(body) do
          marker when is_binary(marker) and marker !== "" ->
            fetch_databases_page(Keyword.put(opts, :marker, marker), accumulated)

          _no_more_pages ->
            {:ok, accumulated}
        end

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

  defp extract_instances(body) do
    SweetXml.xpath(body, ~x"//DBInstances/DBInstance"l,
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
  end

  defp extract_marker(body), do: SweetXml.xpath(body, ~x"//Marker/text()"s)

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
        |> Enum.to_list()
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

  @doc """
  Gets database connection info by name or identifier.
  Returns {:ok, db_info} or {:error, reason}
  """
  def get_database_info(name_or_id, is_identifier \\ false) do
    if is_identifier do
      case fetch_aws_databases_by_identifier(name_or_id) do
        {:ok, [db_info | _]} -> {:ok, db_info}
        {:ok, []} -> {:error, ErrorMessage.not_found("Database with identifier #{name_or_id} not found")}
        {:error, error} -> {:error, error}
      end
    else
      with {:ok, instances} <- fetch_aws_databases() do
        case Enum.find(instances, fn instance -> instance.database == name_or_id end) do
          nil -> {:error, ErrorMessage.not_found("Database #{name_or_id} not found")}
          instance -> {:ok, format_instance(instance)}
        end
      end
    end
  end

  @doc """
  Gets the database password from Terraform state.
  Returns {:ok, password} or {:error, reason}

  ## Options
  - `:backend` - State backend: `:s3` or `:local` (default: from config)
  - `:bucket` - S3 bucket for state (default: from config)
  - `:region` - AWS region (default: from config)
  """
  def get_database_password(db_info, terraform_dir, opts \\ []) do
    with {:ok, state} <- DeployEx.TerraformState.read_state(terraform_dir, opts),
         {:ok, password} <- DeployEx.TerraformState.get_resource_attribute_by_tag(
           state,
           "aws_db_instance",
           "Name",
           db_info.name,
           "password"
         ) do
      {:ok, password}
    end
  end

  @doc """
  Parses a database endpoint string into host and port.
  Returns {host, port}
  """
  def parse_endpoint(endpoint) when is_binary(endpoint) do
    [host, port_str] = String.split(endpoint, ":")
    {host, String.to_integer(port_str)}
  end
end
