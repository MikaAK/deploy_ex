defmodule Mix.Tasks.DeployEx.Ssh do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Ssh into a specific apps remote node"
  @moduledoc """

  ### Example
  ```bash
  $ mix deploy_ex.ssh my_app
  $ mix deploy_ex.ssh my_app 2 # with a specific node
  ```

  What this is really meant for is to be able to create a command that instantly
  connects you to the app. To do this we can do the following:

  Create a bash function that does the following:

  ```bash
  #! /usr/bin/env
  pushd ~/Documents/path/to/project &&
  mix compile &&
  eval "$(mix deploy.ssh -s $@)" &&
  popd
  ```

  You can then set this as an executable and call `./my-script.sh my_app` and it
  will connect you to the node. You can use `--root` or `--log` to do various commands
  on that node

  mix compile

  ### Options
  - `short` - get short form command
  - `root` - get command to connect with root access
  - `log` - get command to remotely monitor logs
  - `log_count` - sets log count to get back
  - `all` - gets all logs instead of just ones for the app
  - `iex` - get command to remotley connect to running node via IEx
  """

  def run(args) do
    {opts, app_params} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         {:ok, app_name} <- find_app_name(releases, app_params),
         {:ok, pem_file_path} <- DeployExHelpers.find_pem_file(opts[:directory]),
         {:ok, hostname_ips} <- DeployExHelpers.terraform_instance_ips(opts[:directory]) do
      connect_to_host(hostname_ips, app_name, pem_file_path, opts)
    else
      {:error, e} -> Mix.shell().raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, extra_args} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, d: :directory, s: :short, n: :log_count],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        short: :boolean,
        root: :boolean,
        log: :boolean,
        log_count: :integer,
        all: :boolean,
        iex: :boolean
      ]
    )

    {opts, extra_args}
  end

  defp find_app_name(_releases, [_, _]) do
    {:error, ErrorMessage.bad_request("only one node is supported")}
  end

  defp find_app_name(releases, [app_name]) do
    case releases |> Keyword.keys |> Enum.find(&(to_string(&1) =~ app_name)) do
      nil -> {:ok, app_name}
      app_name -> {:ok, to_string(app_name)}
    end
  end

  defp connect_to_host(hostname_ips, app_name, pem_file_path, opts) do
    case Enum.find(hostname_ips, fn {key, _} -> to_string(key) =~ app_name end) do
      nil ->
        host_name_ips = inspect(hostname_ips, pretty: true)
        Mix.raise("Couldn't find any app with the name of #{app_name}\n#{host_name_ips}")

      {app_name, ip_addresses} ->
        ip = Enum.random(ip_addresses)
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

  def build_command(app_name, opts) do
    cond do
      opts[:root] ->
        "-t 'sudo -i'"

      opts[:log] ->
        app_name_target = if opts[:all], do: "", else: "-u #{app_name} "
        log_num_count = if opts[:log_count], do: " -n #{opts[:log_count]}", else: ""

        "'sudo -u root journalctl -f #{app_name_target}'#{log_num_count}"

      opts[:iex] ->
        "-t 'sudo -u root /srv/#{app_name}*/bin/#{app_name}* remote'"

      true ->
        ""
    end
  end
end
