defmodule Mix.Tasks.DeployEx.ListAppReleaseHistory do
  use Mix.Task

  @terraform_default_path DeployEx.Config.terraform_folder_path()

  @shortdoc "Lists the latest releases for a specific app via SSH"
  @moduledoc """
  Lists the latest releases for the specified app by connecting to the remote server via SSH.

  ## Example
      mix deploy_ex.list_app_release --app my_app --directory /path/to/dir --pem /path/to/key.pem

  ## Options
    * `--app` or `-a` - The app name to fetch releases for (required)
    * `--directory` or `-d` - Directory to SSH into (required)
    * `--pem` or `-p` - PEM SSH key file (required)
  """

  def run(args) do
    :ssh.start()
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      opts = Keyword.put_new(opts, :directory, @terraform_default_path)

      if extra_args === [] do
        Mix.raise("app is required to be passed in. Example: mix deploy_ex.list_app_release my_app")
      else
        [app_name] = extra_args

        case DeployExHelpers.run_ssh_command_with_return(
          opts[:directory],
          opts[:pem],
          app_name,
          DeployEx.ReleaseController.list_releases()
        ) do
          {:ok, [latest_releases]} ->
            Mix.shell().info([:green, "\nLatest releases for #{app_name}:"])
            Enum.each(String.split(latest_releases, "\n"), fn release ->
              Mix.shell().info([:yellow, "  #{release}"])
            end)

          {:ok, []} ->
            Mix.shell().info([:yellow, "No releases found for #{app_name}."])

          {:error, err} ->
            Mix.raise("Error fetching releases: #{err}")
        end
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [a: :app, d: :directory, p: :pem],
      switches: [app: :string, directory: :string, pem: :string]
    )
  end
end
