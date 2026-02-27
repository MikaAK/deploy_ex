defmodule Mix.Tasks.DeployEx.Grafana.InstallDashboard do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Installs a Grafana dashboard via the HTTP API"
  @moduledoc """
  Installs a Grafana dashboard on your remote Grafana node via the HTTP API.

  Supports importing from a local JSON file or downloading from grafana.com by dashboard ID.

  ## Example
  ```bash
  mix deploy_ex.grafana.install_dashboard --file path/to/dashboard.json
  mix deploy_ex.grafana.install_dashboard --id 19665
  mix deploy_ex.grafana.install_dashboard --id 19665 --user admin --password secret
  mix deploy_ex.grafana.install_dashboard --file dashboard.json --grafana-ip 54.123.45.67
  ```

  ## Options
  - `--file, -f` - Path to a local dashboard JSON file
  - `--id` - Grafana.com dashboard ID (downloads latest revision)
  - `--grafana-ip` - Manual Grafana node IP (skips EC2 discovery)
  - `--grafana-port` - Grafana port (default: 80)
  - `--user` - Grafana admin username (default: admin)
  - `--password` - Grafana admin password (default: admin)
  - `--resource-group` - AWS resource group for node discovery
  - `--pem` - Path to PEM file for SSH tunnel
  - `--quiet, -q` - Suppress output messages
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, _extra_args} = parse_args(args)

      with {:ok, dashboard_json} <- load_dashboard(opts),
           :ok <- print_discovery_info(opts),
           {:ok, result} <- install_dashboard(dashboard_json, opts) do
        print_success(result, opts)
      else
        {:error, error} -> Mix.raise(ErrorMessage.to_string(error))
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :file, q: :quiet],
      switches: [
        file: :string,
        id: :integer,
        grafana_ip: :string,
        grafana_port: :integer,
        user: :string,
        password: :string,
        resource_group: :string,
        pem: :string,
        quiet: :boolean
      ]
    )
  end

  defp load_dashboard(opts) do
    case {opts[:file], opts[:id]} do
      {nil, nil} ->
        {:error, ErrorMessage.bad_request("one of --file or --id is required")}

      {file, id} when not is_nil(file) and not is_nil(id) ->
        {:error, ErrorMessage.bad_request("only one of --file or --id can be provided")}

      {file, nil} ->
        load_from_file(file, opts)

      {nil, id} ->
        download_from_grafana_com(id, opts)
    end
  end

  defp load_from_file(file, opts) do
    if File.exists?(file) do
      unless opts[:quiet] do
        Mix.shell().info([:faint, "Loading dashboard from ", :reset, file])
      end

      case file |> File.read!() |> Jason.decode() do
        {:ok, json} -> {:ok, json}
        {:error, _} -> {:error, ErrorMessage.bad_request("failed to parse JSON from #{file}")}
      end
    else
      {:error, ErrorMessage.not_found("file not found: #{file}")}
    end
  end

  defp download_from_grafana_com(id, opts) do
    unless opts[:quiet] do
      Mix.shell().info([:faint, "Downloading dashboard ", :reset, :cyan, "#{id}", :reset, :faint, " from grafana.com..."])
    end

    case DeployEx.Grafana.download_dashboard(id) do
      {:ok, json} ->
        title = json["title"] || "ID #{id}"

        unless opts[:quiet] do
          Mix.shell().info([:green, "  ✓ ", :reset, "Downloaded \"#{title}\""])
        end

        {:ok, json}

      error ->
        error
    end
  end

  defp print_discovery_info(opts) do
    unless opts[:quiet] do
      Mix.shell().info([:faint, "Discovering Grafana node..."])
    end

    :ok
  end

  defp install_dashboard(dashboard_json, opts) do
    install_opts = [
      grafana_ip: opts[:grafana_ip],
      grafana_port: opts[:grafana_port],
      user: opts[:user],
      password: opts[:password],
      resource_group: opts[:resource_group],
      pem: opts[:pem],
      terraform_directory: @terraform_default_path
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case DeployEx.Grafana.install_dashboard(dashboard_json, install_opts) do
      {:ok, result} ->
        unless opts[:quiet] do
          Mix.shell().info([:green, "  ✓ ", :reset, "Found Grafana node"])
        end

        {:ok, result}

      error ->
        error
    end
  end

  defp print_success(result, opts) do
    unless opts[:quiet] do
      Mix.shell().info([
        :green, "\n✓ Dashboard installed successfully!\n",
        :reset, "\n",
        "  Title: ", :cyan, result.title, :reset, "\n",
        "  UID:   ", :cyan, result.uid || "auto-generated", :reset, "\n",
        "  URL:   ", :cyan, result.url, :reset, "\n"
      ])
    end
  end
end
