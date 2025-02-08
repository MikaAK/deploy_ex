defmodule Mix.Tasks.DeployEx.Ssh do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Ssh into a specific apps remote node"
  @moduledoc """
  Establishes an SSH connection to a remote application node.

  This task allows you to:
  1. Connect directly to an application instance via SSH
  2. View application logs remotely
  3. Connect to a running application via IEx
  4. Execute commands with root access

  ## Basic Usage
  ```bash
  # Connect to a random instance of my_app
  mix deploy_ex.ssh my_app

  # Connect to a specific instance number
  mix deploy_ex.ssh my_app 2
  ```

  ## Shell Script Integration
  You can create a convenient shell script for quick access:

  ```bash
  #!/usr/bin/env bash
  pushd ~/path/to/project &&
  mix compile &&
  eval "$(mix deploy_ex.ssh -s $@)" &&
  popd
  ```

  Make the script executable and use it like:
  ```bash
  ./my-script.sh my_app
  ```

  ## Options
  - `--whitelist` - Add current IP to security group whitelist before connecting
  - `--short`, `-s` - Output command in short form for scripting
  - `--root` - Connect with root user access
  - `--log` - View remote application logs
  - `--log_user` - Specify user for log access (default: ubuntu)
  - `--log_count`, `-n` - Number of log lines to display
  - `--all` - Show all system logs, not just application logs
  - `--iex` - Connect to running application node via IEx
  - `--directory`, `-d` - Directory containing SSH keys (default: ./deploys/terraform)
  - `--force`, `-f` - Skip confirmation prompts
  - `--quiet`, `-q` - Suppress non-essential output
  """

  def run(args) do
    Enum.each([:req, :hackney, :ex_aws], &Application.ensure_all_started/1)

    {opts, app_params} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, app_name} <- DeployExHelpers.find_app_name(app_params),
         {:ok, pem_file_path} <- DeployExHelpers.find_pem_file(opts[:directory]),
         {:ok, hostname_ips} <- DeployExHelpers.aws_instance_groups() do
      connect_to_host(hostname_ips, app_name, pem_file_path, opts)
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet, d: :directory, s: :short, n: :log_count],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        short: :boolean,
        root: :boolean,
        log: :boolean,
        log_count: :integer,
        log_user: :string,
        all: :boolean,
        iex: :boolean
      ]
    )
  end

  defp connect_to_host(hostname_ips, app_name, pem_file_path, opts) do
    case Enum.find(hostname_ips, fn {key, _} -> to_string(key) =~ app_name end) do
      nil ->
        host_name_ips = inspect(hostname_ips, pretty: true)
        Mix.raise("Couldn't find any app with the name of #{app_name}\n#{host_name_ips}")

      {app_name, [%{ip: ip}]} ->
        log_ssh_command(app_name, pem_file_path, ip, opts)

      {app_name, instances} ->
        instance = Enum.random(Enum.sort(instances)) # DeployExHelpers.prompt_for_choice

        log_ssh_command(app_name, pem_file_path, instance.ip, opts)

        # When using Rambo re-enable
        # Mix.shell().info([
        #   :green, "Attempting to connect to ",
        #   :reset, app_name, :green, " at ",
        #   :reset, ip, :green, " using pem file ",
        #   :reset, pem_file_path
        # ])

        # with {:error, e} <- DeployExHelpers.run_command_with_input("ssh -i #{pem_file_path} admin@#{ip}", "") do
        #   Mix.shell().error(to_string(e))
        # end
    end
  end

  defp log_ssh_command(app_name, pem_file_path, ip, opts) do
    command = build_command(app_name, opts)

    if opts[:short] do
      Mix.shell().info("ssh -i #{pem_file_path} admin@#{ip} #{command}")
    else
      Mix.shell().info([
        :green, "Use the following comand to connect to ",
        :reset, app_name || "Unknown", :green, " \"",
        :reset, "ssh -i #{pem_file_path} admin@#{ip} ", command,
        :green, "\""
      ])
    end
  end

  def build_command(app_name, opts) do
    cond do
      opts[:root] ->
        "-t 'sudo -i'"

      opts[:log] ->
        log_num_count = if opts[:log_count], do: " -n #{opts[:log_count]}", else: ""

        "'sudo -u root journalctl -f #{app_name_target(app_name, opts)}'#{log_num_count}"

      opts[:iex] ->
        "-t 'sudo -u root /srv/#{app_name}*/bin/#{app_name}* remote'"

      true ->
        ""
    end
  end

  defp app_name_target(app_name, opts) do
    cond do
      opts[:all] -> ""
      opts[:log_user] -> "-u #{opts[:log_user]} "
      true -> "-u #{app_name} "
    end
  end
end
