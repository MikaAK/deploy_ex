defmodule Mix.Tasks.Terraform.DumpDatabase do
  use Mix.Task

  alias DeployEx.{AwsDatabase, AwsMachine, SSH}

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
  - `--output` - Output file path (default: ./dump_<timestamp>.sql)
  - `--directory` - Terraform directory path
  - `--schema-only` - Only dump the schema, no data
  - `--local-port` - Local port to use for SSH tunnel (default: random available port)
  - `--identifier` - Use RDS instance identifier instead of database name
  - `--format` - Output format (default: custom, options: custom|text)
  - `--resource-group` - Specify a custom resource group name (default: "<ProjectName> Backend")
  - `--pem` - Specify a custom pem file

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
    {machine_opts, opts} = Keyword.split(opts, [:resource_group])

    with :ok <- check_pg_dump_installed(),
         :ok <- DeployExHelpers.check_in_umbrella(),
         database_name when not is_nil(database_name) <- List.first(extra_args) || show_database_selection(),
         {:ok, db_info} <- AwsDatabase.get_database_info(database_name, opts[:identifier]),
         {:ok, password} <- AwsDatabase.get_database_password(db_info, opts[:directory]),
         {:ok, {jump_server_ip, jump_server_ipv6}} <- AwsMachine.find_jump_server(DeployExHelpers.project_name(), machine_opts),
         {:ok, local_port} <- get_local_port(opts[:local_port]),
         {host, port} <- AwsDatabase.parse_endpoint(db_info.endpoint),
         {:ok, pem_file} <- DeployEx.Terraform.find_pem_file(opts[:directory], opts[:pem]),
         :ok <- SSH.setup_ssh_tunnel(
          jump_server_ipv6 || jump_server_ip,
          host,
          port,
          local_port,
          pem_file
          ) do

      Mix.shell().info([:green, "Connected a tunnel to #{jump_server_ipv6 || jump_server_ip}:#{port}"])

      db_info = Map.put(db_info, :password, password)
      case execute_dump(db_info, local_port, opts) do
        :ok ->
          SSH.cleanup_tunnel(local_port)
          :ok
        {:error, error} ->
          SSH.cleanup_tunnel(local_port)
          Mix.raise("Failed to dump database: #{error}")
      end
    else
      nil -> Mix.raise("No database name provided")
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp get_local_port(nil), do: SSH.find_available_port()
  defp get_local_port(port), do: {:ok, port}

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [d: :directory, o: :output, s: :schema_only, p: :local_port, i: :identifier, f: :format, p: :pem],
      switches: [
        directory: :string,
        output: :string,
        schema_only: :boolean,
        local_port: :integer,
        identifier: :string,
        format: :string,
        resource_group: :string,
        pem: :string
      ]
    )
  end

  defp check_pg_dump_installed do
    case System.find_executable("pg_dump") do
      nil -> {:error, "pg_dump not found. Please install PostgreSQL client tools"}
      _path -> :ok
    end
  end

  defp execute_dump(db_info, local_port, opts) do
    output_file = build_output_filename(db_info.database, opts)
    format_flag = get_format_flag(opts[:format] || "custom")
    schema_flag = get_schema_flag(opts[:schema_only])

    Mix.shell().info([:yellow, "Starting database dump to #{output_file}"])

    pg_dump = System.find_executable("pg_dump")
    env = [{"PGPASSWORD", db_info.password}]
    args = [
      "-h", "localhost",
      "-p", to_string(local_port),
      "-U", db_info.username,
      format_flag,
      schema_flag,
      db_info.database,
      "-f", output_file
    ]
    |> Enum.filter(&(&1 != ""))

    case System.cmd(pg_dump, args, env: env, stderr_to_stdout: true) do
      {_, 0} ->
        Mix.shell().info([:green, "Database dump saved to ", :reset, output_file])
        :ok

      {error, _} -> {:error, error}
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

  defp show_database_selection do
    case AwsDatabase.fetch_aws_databases() do
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
