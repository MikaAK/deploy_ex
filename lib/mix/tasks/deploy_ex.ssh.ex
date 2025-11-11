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

  # Connect to a specific instance by index
  mix deploy_ex.ssh my_app --index 2

  # List all instances and their IPs
  mix deploy_ex.ssh my_app --list
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
  - `--pem`, `-p` - Pem file to use, default will use first found
  - `--directory`, `-d` - Directory containing SSH keys (default: ./deploys/terraform)
  - `--force`, `-f` - Skip confirmation prompts
  - `--quiet`, `-q` - Suppress non-essential output
  - `--resource_group` - Specify the resource group to connect to
  - `--index`, `-i` - Connect to a specific instance by index (0-based)
  - `--list`, `-l` - List all instances and their IPs without connecting
  """

  def run(args) do
    Enum.each([:req, :hackney, :ex_aws], &Application.ensure_all_started/1)

    {opts, app_params} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    {machine_opts, opts} = Keyword.split(opts, [:resource_group])

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, app_name} <- DeployExHelpers.find_project_name(app_params),
         {:ok, instance_ips} <- DeployEx.AwsMachine.find_instance_ips(DeployExHelpers.project_name(), app_name, machine_opts) do
      if opts[:list] do
        list_instances(app_name, instance_ips)
      else
        {:ok, pem_file_path} = DeployEx.Terraform.find_pem_file(opts[:directory], opts[:pem])
        connect_to_host(app_name, instance_ips, pem_file_path, opts)
      end
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet, d: :directory, s: :short, n: :log_count, p: :pem, i: :index, l: :list],
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
        iex: :boolean,
        pem: :string,
        resource_group: :string,
        index: :integer,
        list: :boolean
      ]
    )
  end

  defp list_instances(app_name, []) do
    Mix.shell().info([:yellow, "No instances found for #{app_name}"])
  end

  defp list_instances(app_name, instance_ips) do
    Mix.shell().info([
      :green, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
      :bright, "Instances for: ", :normal, app_name, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    ])

    instance_ips
    |> Enum.with_index()
    |> Enum.each(fn {ip, index} ->
      Mix.shell().info([
        :cyan, "  [#{index}] ", :reset, ip
      ])
    end)

    Mix.shell().info([
      :green, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
      :reset, "Total instances: ", :bright, "#{length(instance_ips)}", :reset, "\n",
      "Use ", :cyan, "--index N", :reset, " to connect to a specific instance\n"
    ])
  end

  defp connect_to_host(app_name, [], _pem_file_path, _opts) do
    Mix.raise("Couldn't find any app with the name of #{app_name}")
  end

  defp connect_to_host(app_name, instance_ips, pem_file_path, opts) do
    instance_ip = cond do
      opts[:index] !== nil ->
        case Enum.at(instance_ips, opts[:index]) do
          nil ->
            Mix.raise("Instance index #{opts[:index]} not found. Available: 0..#{length(instance_ips) - 1}")
          ip ->
            ip
        end

      opts[:short] ->
        Enum.random(instance_ips)

      true ->
        DeployExHelpers.prompt_for_choice(instance_ips, false)
    end

    log_ssh_command(app_name, pem_file_path, instance_ip, opts)

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
