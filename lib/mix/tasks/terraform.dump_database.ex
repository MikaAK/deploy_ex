defmodule Mix.Tasks.Terraform.DumpDatabase do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Dumps a database from RDS through a jump server"
  @moduledoc """
  Dumps a database from RDS through a jump server using pg_dump.
  Requires local PostgreSQL client tools to be installed.

  ## Example
  ```bash
  mix terraform.dump_database database_name [--output my_dump.sql]
  mix terraform.dump_database --identifier my-db-identifier [--output my_dump.sql]
  ```

  ## Options
  - `output` - Output file path (default: ./dump_<timestamp>.sql)
  - `directory` - Terraform directory path
  - `schema-only` - Only dump the schema, no data
  - `local-port` - Local port to use for SSH tunnel (default: random available port)
  - `identifier` - Use RDS instance identifier instead of database name
  - `format` - Output format (default: custom, options: custom|text)

  ## Format Options
  The `--format` flag accepts two values:

  - `custom`: PostgreSQL's custom format (default)
    - Produces a compressed binary file
    - Can only be restored with pg_restore
    - Allows selective restore of tables/schemas
    - Better handling of large objects
    - Supports parallel restore

  - `text`: Plain SQL format
    - Human readable SQL statements
    - Can be edited manually if needed
    - Can be restored with psql
    - Useful for version control
    - Slower restore compared to custom format
    - No parallel restore support
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, extra_args} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with :ok <- check_pg_dump_installed(),
         :ok <- DeployExHelpers.check_in_umbrella(),
         database_name when not is_nil(database_name) <- List.first(extra_args) || show_database_selection(),
         {:ok, db_info} <- get_database_info(database_name, opts[:identifier]),
         {:ok, state} <- DeployEx.TerraformState.read_state(opts[:directory]),
         {:ok, password} <- DeployEx.TerraformState.get_resource_attribute_by_tag(
           state,
           "aws_db_instance",
           "Name",
           db_info.name,
           "password"
         ),
         {:ok, jump_server} <- find_jump_server(),
         {:ok, local_port} <- find_available_port(opts[:local_port]),
         :ok <- setup_ssh_tunnel(jump_server, db_info, local_port, opts),
         :ok <- execute_dump(Map.put(db_info, :password, password), local_port, opts) do
      :ok
    else
      nil -> Mix.raise("No database name provided")
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [d: :directory, o: :output, s: :schema_only, p: :local_port, i: :identifier, f: :format],
      switches: [
        directory: :string,
        output: :string,
        schema_only: :boolean,
        local_port: :integer,
        identifier: :string,
        format: :string
      ]
    )
  end

  defp check_pg_dump_installed do
    case System.find_executable("pg_dump") do
      nil -> {:error, "pg_dump not found. Please install PostgreSQL client tools"}
      _path -> :ok
    end
  end

  defp get_database_info(database_name, identifier) do
    if identifier do
      case DeployEx.AwsDatabase.fetch_aws_databases_by_identifier(identifier) do
        {:ok, [db_info | _]} -> {:ok, db_info}
        {:ok, []} -> {:error, ErrorMessage.not_found("Database with identifier #{identifier} not found")}
        {:error, error} -> {:error, ErrorMessage.internal_server_error("Failed to get database info", %{error: error})}
      end
    else
      case DeployEx.AwsDatabase.fetch_aws_databases() do
        {:ok, instances} ->
          case Enum.find(instances, fn instance -> instance.database == database_name end) do
            nil -> {:error, ErrorMessage.not_found("Database #{database_name} not found")}
            instance -> {:ok, format_instance(instance)}
          end
        {:error, error} -> {:error, ErrorMessage.internal_server_error("Failed to get database info", %{error: error})}
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

  defp get_name_tag(instance) do
    Enum.find_value(instance.tags, instance.identifier, fn
      %{key: "Name", value: value} -> value
      _ -> false
    end)
  end

  defp find_jump_server do
    with {:ok, instances} <- DeployExHelpers.aws_instance_groups() do
      server_ips = Enum.flat_map(instances, fn {name, instances} ->
        Enum.map(instances, fn %{ip: ip, name: server_name} -> {ip, "#{name} (#{server_name})"} end)
      end)

      case server_ips do
        [{ip, _}] -> {:ok, ip}  # Single server case

        servers when servers !== [] ->
          [choice] = DeployExHelpers.prompt_for_choice(Enum.map(servers, fn {_, name} -> name end))
          {ip, _} = Enum.find(servers, fn {_, name} -> name == choice end)
          {:ok, ip}

        _ -> {:error, ErrorMessage.not_found("No jump servers found")}
      end
    end
  end

  defp find_available_port(nil) do
    case :gen_tcp.listen(0, []) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}
      {:error, reason} ->
        {:error, ErrorMessage.internal_server_error("Failed to find available port", %{reason: reason})}
    end
  end
  defp find_available_port(port), do: {:ok, port}

  defp setup_ssh_tunnel(jump_server_ip, db_info, local_port, opts) do
    {host, port} = parse_endpoint(db_info.endpoint)

    with {:ok, pem_file} <- DeployExHelpers.find_pem_file(opts[:directory]) do
      abs_pem_file = Path.expand(pem_file)
      ssh_cmd = "ssh -i #{abs_pem_file} -f -N -L #{local_port}:#{host}:#{port} admin@#{jump_server_ip}"

      case System.shell(ssh_cmd) do
        {_, 0} -> :ok
        {error, code} ->
          {:error, ErrorMessage.internal_server_error("Failed to setup SSH tunnel", %{error: error, code: code})}
      end
    end
  end

  defp parse_endpoint(endpoint) do
    [host, port_str] = String.split(endpoint, ":")
    {host, String.to_integer(port_str)}
  end

  defp execute_dump(db_info, local_port, opts) do
    output_file = build_output_filename(db_info.database, opts)
    format_flag = get_format_flag(opts[:format] || "custom")
    schema_flag = get_schema_flag(opts[:schema_only])

    Mix.shell().info([:yellow, "Starting database dump to #{output_file}"])

    case run_pg_dump(db_info, local_port, output_file, format_flag, schema_flag) do
      :ok ->
        Mix.shell().info([:green, "Database dump saved to ", :reset, output_file])
        cleanup_tunnel(local_port)
        :ok
      {:error, error} ->
        cleanup_tunnel(local_port)
        {:error, ErrorMessage.internal_server_error("Failed to dump database", %{error: error})}
    end
  end

  defp build_output_filename(database, opts) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    format = opts[:format] || "custom"
    extension = if format == "custom", do: ".pgdump", else: ".sql"
    opts[:output] || "./#{database}_dump_#{timestamp}#{extension}"
  end

  defp get_format_flag(format) do
    case format do
      "custom" -> "-Fc"
      "text" -> "-Fp"
      _ -> Mix.raise("Unsupported format: #{format}. Supported formats are 'custom' or 'text'")
    end
  end

  defp get_schema_flag(schema_only) do
    if schema_only, do: "--schema-only", else: ""
  end

  defp run_pg_dump(db_info, local_port, output_file, format_flag, schema_flag) do
    pg_dump_cmd = "PGPASSWORD='#{db_info.password}' pg_dump -h localhost -p #{local_port} " <>
                  "-U #{db_info.username} #{schema_flag} #{format_flag} #{db_info.database} > #{output_file}"

    case System.shell(pg_dump_cmd) do
      {_, 0} -> :ok
      {error, _} -> {:error, error}
    end
  end

  defp cleanup_tunnel(local_port) do
    System.shell("pkill -f 'ssh.*#{local_port}'")
  end

  defp show_database_selection() do
    case DeployEx.AwsDatabase.fetch_aws_databases() do
      {:ok, instances} ->
        database_names = Enum.map(instances, & &1.database)
        case database_names do
          [] -> nil
          [single_db] -> single_db
          multiple_dbs ->
            [choice] = DeployExHelpers.prompt_for_choice(multiple_dbs)
            choice
        end
      _ -> nil
    end
  end
end
