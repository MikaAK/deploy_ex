defmodule Mix.Tasks.Terraform.RestoreDatabase do
  use Mix.Task

  alias DeployEx.{AwsDatabase, AwsMachine, SSH}

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Restores a database dump to either RDS or local PostgreSQL"
  @moduledoc """
  Restores a database dump file to either an RDS instance through a jump server
  or to a local PostgreSQL instance. Automatically detects dump format and uses
  appropriate restore tool (pg_restore for custom format, psql for text format).

  ## Example
  ```bash
  # Restore to RDS instance
  mix terraform.restore_database my-database dump_file.pgdump

  # Restore to local PostgreSQL
  mix terraform.restore_database my_database dump_file.sql --local

  # Restore only schema
  mix terraform.restore_database my-database dump_file.pgdump --schema-only
  ```

  ## Options
  - `--local` - Restore to local PostgreSQL instead of RDS
  - `--directory` - Terraform directory path
  - `--schema-only` - Only restore the schema, no data
  - `--local-port` - Local port to use for SSH tunnel (default: random available port)
  - `--clean` - Drop database objects before recreating them
  - `--jobs` - Number of parallel jobs for restore (custom format only)
  - `--resource-group` - Specify a custom resource group name (default: "<ProjectName> Backend")
  - `--pem` - Specify a custom pem file
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, extra_args} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with :ok <- check_restore_tools_installed(),
         {database_name, dump_file} <- parse_extra_args(extra_args),
         :ok <- check_dump_file_exists(dump_file),
         format <- detect_dump_format(dump_file),
         {:ok, connection_info} <- get_connection_info(database_name, opts),
         {:ok, connection_info} <- setup_connection(connection_info, opts) do

      Mix.shell().info([:yellow, "Restoring database #{database_name} from #{dump_file}"])

      restore_result = if format == "custom" do
        run_pg_restore(dump_file, connection_info, opts)
      else
        run_psql_restore(dump_file, connection_info, opts)
      end

      case restore_result do
        :ok ->
          cleanup_connection(connection_info)
          Mix.shell().info([:green, "Database restore completed successfully"])
          :ok
        {:error, error} ->
          cleanup_connection(connection_info)
          Mix.raise("Failed to restore database: #{error}")
      end
    else
      {:error, error} -> Mix.raise(to_string(error))
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [d: :directory, s: :schema_only, p: :local_port, l: :local, p: :pem],
      switches: [
        directory: :string,
        local: :boolean,
        schema_only: :boolean,
        local_port: :integer,
        clean: :boolean,
        jobs: :integer,
        resource_group: :string,
        pem: :string
      ]
    )
  end

  defp parse_extra_args([database_name, dump_file | _]) do
    {database_name, dump_file}
  end
  defp parse_extra_args(_) do
    {:error, "Must provide both database name and dump file path"}
  end

  defp check_restore_tools_installed do
    with nil <- System.find_executable("psql") do
      Mix.raise("PostgreSQL client tools (psql) not found. Please install PostgreSQL client tools.")
    end

    with nil <- System.find_executable("pg_restore") do
      Mix.raise("PostgreSQL client tools (pg_restore) not found. Please install PostgreSQL client tools.")
    end

    :ok
  end

  defp check_dump_file_exists(dump_file) do
    if File.exists?(dump_file) do
      :ok
    else
      {:error, "Dump file not found: #{dump_file}"}
    end
  end

  defp detect_dump_format(dump_file) do
    case Path.extname(dump_file) do
      ".pgdump" -> "custom"
      ".sql" -> "text"
      ext -> Mix.raise("Unsupported dump file format: #{ext}. Expected .pgdump or .sql")
    end
  end

  defp get_connection_info(database_name, opts) do
    if opts[:local] do
      {:ok, %{
        host: "localhost",
        port: 5432,
        database: database_name,
        username: System.get_env("USER"),
        password: nil,
        local: true
      }}
    else
      with {:ok, db_info} <- AwsDatabase.get_database_info(database_name, false),
           {:ok, password} <- AwsDatabase.get_database_password(db_info, opts[:directory]) do
        {:ok, Map.merge(db_info, %{
          password: password,
          local: false
        })}
      end
    end
  end

  defp get_local_port(nil), do: SSH.find_available_port()
  defp get_local_port(port), do: {:ok, port}

  defp setup_connection(connection_info, opts) do
    if connection_info.local do
      {:ok, connection_info}
    else
      {machine_opts, opts} = Keyword.split(opts, [:resource_group])

      with {:ok, {jump_server_ip, jump_server_ipv6}} <- AwsMachine.find_jump_server(DeployExHelpers.project_name(), machine_opts),
           {:ok, local_port} <- get_local_port(opts[:local_port]),
           {host, port} <- AwsDatabase.parse_endpoint(connection_info.endpoint),
           {:ok, pem_file} <- DeployEx.Terraform.find_pem_file(opts[:directory], opts[:pem]),
           :ok <- SSH.setup_ssh_tunnel(jump_server_ipv6 || jump_server_ip, host, port, local_port, pem_file) do
        Mix.shell().info([:green, "Connected a tunnel to #{jump_server_ipv6 || jump_server_ip}:#{port}"])

        {:ok, Map.put(connection_info, :local_port, local_port)}
      end
    end
  end

  defp cleanup_connection(%{local: true}), do: :ok
  defp cleanup_connection(%{local_port: port}), do: SSH.cleanup_tunnel(port)

  defp run_pg_restore(dump_file, connection_info, opts) do
    pg_restore = System.find_executable("pg_restore")
    jobs_flag = if opts[:jobs], do: "-j #{opts[:jobs]}", else: ""
    schema_flag = if opts[:schema_only], do: "--schema-only", else: ""
    clean_flag = if opts[:clean], do: "--clean", else: ""

    {host, port} = get_connection_details(connection_info)

    env = if connection_info.password, do: [{"PGPASSWORD", connection_info.password}], else: []
    args = [
      "-h", host,
      "-p", to_string(port),
      "-U", connection_info.username,
      "-d", connection_info.database
    ] ++ String.split("#{jobs_flag} #{schema_flag} #{clean_flag}", " ", trim: true) ++ [dump_file]

    case System.cmd(pg_restore, args, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> {:error, error}
    end
  end

  defp run_psql_restore(dump_file, connection_info, opts) do
    psql = System.find_executable("psql")
    schema_flag = if opts[:schema_only], do: "--schema-only", else: ""

    {host, port} = get_connection_details(connection_info)

    env = if connection_info.password, do: [{"PGPASSWORD", connection_info.password}], else: []
    args = [
      "-h", host,
      "-p", to_string(port),
      "-U", connection_info.username,
      "-d", connection_info.database
    ] ++ String.split(schema_flag, " ", trim: true) ++ ["-f", dump_file]

    case System.cmd(psql, args, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> {:error, error}
    end
  end

  defp get_connection_details(%{local: true} = info), do: {info.host, info.port}
  defp get_connection_details(info), do: {"localhost", info.local_port}
end
