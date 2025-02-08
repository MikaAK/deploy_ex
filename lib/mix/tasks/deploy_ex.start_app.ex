defmodule Mix.Tasks.DeployEx.StartApp do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Starts a specific application's systemd service"
  @moduledoc """
  Starts the systemd service for a specified application on the target server.

  This task:
  1. Connects to the server running the application via SSH
  2. Issues a systemd start command for the application's service
  3. Verifies the service starts successfully

  The application name can be a partial match - it will find the first matching application.

  ## Example
  ```bash
  # Start the my_app service
  mix deploy_ex.start_app my_app

  # Start with custom SSH key directory
  mix deploy_ex.start_app my_app --directory /path/to/keys
  ```

  ## Options
  - `directory` - Directory containing SSH keys (default: ./deploys/terraform) (alias: `d`)
  - `force` - Skip confirmation prompt (alias: `f`)
  - `quiet` - Suppress output messages (alias: `q`)
  """

  def run(args) do
    :ssh.start()

    {opts, node_name_args} = parse_args(args)
    opts = Keyword.put_new(opts, :directory, @terraform_default_path)

    with {:ok, app_name} <- DeployExHelpers.find_app_name(node_name_args),
         _ = Mix.shell().info([:yellow, "Starting #{app_name} systemd service"]),
         :ok <- start_service(app_name, opts) do
      Mix.shell().info([:green, "Started #{app_name} systemd service successfully"])
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp start_service(app_name, opts) do
    DeployExHelpers.run_ssh_command(
      opts[:directory],
      app_name,
      DeployEx.SystemDController.start_service(app_name)
    )
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet, d: :directory],
      switches: [
        directory: :string,
        force: :boolean,
        quiet: :boolean
      ]
    )
  end
end
