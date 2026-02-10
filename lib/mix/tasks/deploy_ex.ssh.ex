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
  - `--qa` - Show only QA nodes (optionally filter by app_name)
  """

  def run(args) do
    Enum.each([:req, :hackney, :ex_aws], &Application.ensure_all_started/1)

    {opts, app_params} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    {machine_opts, opts} = Keyword.split(opts, [:resource_group])

    with :ok <- DeployExHelpers.check_in_umbrella() do
      if opts[:qa] do
        app_name = List.first(app_params)
        run_qa_mode(app_name, machine_opts, opts)
      else
        run_app_mode(app_params, machine_opts, opts)
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
        list: :boolean,
        qa: :boolean,
        instance_id: :keep
      ]
    )
  end

  defp run_qa_mode(app_name, machine_opts, opts) do
    case DeployEx.AwsMachine.find_qa_instance_ips(app_name, machine_opts) do
      {:ok, []} ->
        Mix.shell().info([:yellow, "No QA nodes found"])

      {:ok, qa_instances} ->
        if opts[:list] do
          list_qa_instances(qa_instances)
        else
          {:ok, pem_file_path} = DeployEx.Terraform.find_pem_file(opts[:directory], opts[:pem])
          connect_to_qa_host(qa_instances, pem_file_path, opts)
        end

      {:error, e} ->
        Mix.raise(to_string(e))
    end
  end

  defp run_app_mode(app_params, machine_opts, opts) do
    instance_ids = Keyword.get_values(opts, :instance_id)

    with {:ok, app_name} <- find_app_name_or_default(app_params, instance_ids),
         {:ok, instance_ips} <- find_instance_ips_for_app_or_instance_ids(app_name, instance_ids, machine_opts) do
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

  defp find_app_name_or_default(app_params, []) do
    DeployExHelpers.find_project_name(app_params)
  end

  defp find_app_name_or_default(_app_params, instance_ids) when is_list(instance_ids) do
    {:ok, nil}
  end

  defp find_instance_ips_for_app_or_instance_ids(app_name, [], machine_opts) do
    machine_opts = Keyword.put(machine_opts, :exclude_qa_nodes, true)
    DeployEx.AwsMachine.find_instance_ips(DeployExHelpers.project_name(), app_name, machine_opts)
  end

  defp find_instance_ips_for_app_or_instance_ids(_app_name, instance_ids, machine_opts) do
    region = machine_opts[:region] || DeployEx.Config.aws_region()

    with {:ok, instances} <- DeployEx.AwsMachine.find_instances_by_id(region, instance_ids) do
      instance_ips =
        instances
        |> Enum.map(fn instance -> instance["ipv6Address"] || instance["ipAddress"] end)
        |> Enum.reject(&is_nil/1)

      {:ok, instance_ips}
    end
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

  defp list_qa_instances(qa_instances) do
    Mix.shell().info([
      :green, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
      :bright, "QA Nodes", :normal, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    ])

    qa_instances
    |> Enum.with_index()
    |> Enum.each(fn {{name, ip}, index} ->
      Mix.shell().info([
        :cyan, "  [#{index}] ", :reset, name, " (", ip, ")"
      ])
    end)

    Mix.shell().info([
      :green, "\n",
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
      :reset, "Total QA nodes: ", :bright, "#{length(qa_instances)}", :reset, "\n",
      "Use ", :cyan, "--index N", :reset, " to connect to a specific instance\n"
    ])
  end

  defp connect_to_qa_host(qa_instances, pem_file_path, opts) do
    {name, ip} = cond do
      opts[:index] !== nil ->
        instance = Enum.at(qa_instances, opts[:index])

        if is_nil(instance) do
          Mix.raise("Instance index #{opts[:index]} not found. Available: 0..#{length(qa_instances) - 1}")
        else
          instance
        end

      opts[:short] ->
        Enum.random(qa_instances)

      true ->
        choices = Enum.map(qa_instances, fn {name, ip} -> "#{name} (#{ip})" end)
        [choice] = DeployExHelpers.prompt_for_choice(choices, false)
        Enum.find(qa_instances, fn {name, ip} -> "#{name} (#{ip})" === choice end)
    end

    app_name = extract_app_name_from_qa_node(name)
    log_ssh_command(app_name, pem_file_path, ip, opts)
  end

  defp extract_app_name_from_qa_node(name) do
    case Regex.run(~r/^(.+)-qa-\d+$/, name) do
      [_, app_name] -> app_name
      _ -> name
    end
  end

  defp connect_to_host(app_name, [], _pem_file_path, _opts) do
    Mix.raise("Couldn't find any app with the name of #{app_name}")
  end

  defp connect_to_host(app_name, instance_ips, pem_file_path, opts) do
    instance_ip = cond do
      opts[:index] !== nil ->
        instance_ip = Enum.at(instance_ips, opts[:index])

        if is_nil(instance_ip) do
          Mix.raise("Instance index #{opts[:index]} not found. Available: 0..#{length(instance_ips) - 1}")
        else
          instance_ip
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
