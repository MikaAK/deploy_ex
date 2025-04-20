defmodule Mix.Tasks.DeployEx.DownloadFile do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Downloads a file from a remote server using SCP"
  @moduledoc """
  Downloads a file from a remote server using SCP. This task allows you to securely copy files from
  your remote application servers to your local machine.

  ## Usage
  ```bash
  mix deploy_ex.download_file APP_NAME REMOTE_PATH [LOCAL_PATH]
  ```

  Where:
  - `APP_NAME` is the name of your application/server to download from
  - `REMOTE_PATH` is the full path to the file on the remote server
  - `LOCAL_PATH` is optional and defaults to the basename of REMOTE_PATH in current directory

  ## Examples
  ```bash
  # Download /var/log/app.log to ./app.log
  mix deploy_ex.download_file my_app /var/log/app.log

  # Download to specific local path
  mix deploy_ex.download_file my_app /etc/myapp/config.json ./downloads/remote-config.json

  # Force overwrite existing file
  mix deploy_ex.download_file my_app /var/log/app.log --force
  ```

  ## Options
  - `--directory`, `-d` - Terraform directory path containing SSH keys (default: #{@terraform_default_path})
  - `--force`, `-f` - Force overwrite if local file exists
  - `--quiet`, `-q` - Suppress informational output messages
  - `--resource_group`, - Specify the resource group to connect to
  - `--pem`, `-p` - SSH key file

  ## Requirements
  - SSH access to the remote server must be configured
  - The remote file must be readable by the SSH user
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    {opts, node_name_args} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, [app_name, remote_path, local_path]} <- parse_node_name_args(node_name_args),
         {:ok, app_name} <- DeployExHelpers.find_project_name([app_name]),
         _ = Mix.shell().info([:yellow, "Downloading #{remote_path} from #{app_name}"]),
         :ok <- download_file(app_name, remote_path, local_path, opts) do
      Mix.shell().info([:green, "Downloaded #{remote_path} to #{local_path} successfully"])
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_node_name_args(args) do
    case args do
      [app_name, remote_path | rest] ->
        {:ok, [app_name, remote_path, List.first(rest) || Path.basename(remote_path)]}

      _ ->
        {:error, "Expected arguments: <app_name> <remote_path> [local_path]"}
    end
  end

  defp download_file(app_name, remote_path, local_path, opts) do
    if File.exists?(local_path) and not !!opts[:force] do
      {:error, "File #{local_path} already exists. Use --force to overwrite."}
    else
      {machine_opts, opts} = Keyword.split(opts, [:resource_group])

      with {:ok, pem_file_path} <- DeployEx.Terraform.find_pem_file(opts[:directory], opts[:pem]),
         {:ok, instance_ips} <- DeployEx.AwsMachine.find_instance_ips(DeployExHelpers.project_name(), app_name, machine_opts) do

        ip = List.first(instance_ips)

        abs_pem_file = Path.expand(pem_file_path)
        abs_local_path = Path.expand(local_path)

        scp_cmd = "scp -i #{abs_pem_file} admin@#{ip}:#{remote_path} #{abs_local_path}"

        DeployEx.Utils.run_command(scp_cmd, File.cwd!())
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet, d: :directory, p: :pem],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean,
        resource_group: :string,
        pem: :string
      ]
    )
  end
end
