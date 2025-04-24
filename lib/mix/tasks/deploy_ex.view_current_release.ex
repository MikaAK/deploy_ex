defmodule Mix.Tasks.DeployEx.ViewCurrentRelease do
  use Mix.Task

  @shortdoc "Shows the current (latest) release for a specific app via SSH"
  @moduledoc """
  Shows the current (latest) release for the specified app by connecting to the remote server via SSH.

  ## Example
      mix deploy_ex.view_current_release my_app --directory /path/to/dir --pem /path/to/key.pem

  ## Options
    * `--directory` or `-d` - Directory to SSH into (optional, defaults to Terraform path)
    * `--pem` or `-p` - PEM SSH key file (required)
  """

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)
      opts = Keyword.put_new(opts, :directory, @terraform_default_path)

      if extra_args == [] do
        Mix.raise("app_name is required. Example: mix deploy_ex.view_current_release my_app")
      else
        [app_name] = extra_args

        case DeployExHelpers.run_ssh_command_with_return(
               opts[:directory],
               opts[:pem],
               app_name,
               DeployEx.ReleaseController.current_release()
             ) do
          {:ok, [current_release | _]} ->
            Mix.shell().info([:green, "\nCurrent release for #{app_name}:\n  ", :yellow, current_release])
          {:ok, []} ->
            Mix.shell().info([:yellow, "No releases found for #{app_name}."])
          {:error, err} ->
            Mix.raise("Error fetching current release: #{err}")
        end
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [d: :directory, p: :pem],
      switches: [directory: :string, pem: :string]
    )
  end
end
