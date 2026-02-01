defmodule Mix.Tasks.DeployEx.ListAppReleaseHistory do
  use Mix.Task

  @shortdoc "Lists the release history for a specific app from S3"
  @moduledoc """
  Lists the release history for the specified app by fetching from S3.

  ## Example
      mix deploy_ex.list_app_release_history my_app
      mix deploy_ex.list_app_release_history my_app --limit 10

  ## Options
    * `--limit` or `-l` - Number of releases to show (default: 25)
    * `--aws-region` - AWS region (optional, defaults to config)
    * `--aws-bucket` - S3 bucket for releases (optional, defaults to config)
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, extra_args} = parse_args(args)

      opts = opts
        |> Keyword.put_new(:region, DeployEx.Config.aws_region())
        |> Keyword.put_new(:bucket, DeployEx.Config.aws_release_bucket())
        |> Keyword.put_new(:limit, 25)

      if extra_args === [] do
        Mix.raise("app is required to be passed in. Example: mix deploy_ex.list_app_release_history my_app")
      else
        with {:ok, app_name} <- DeployExHelpers.find_project_name(extra_args),
             {:ok, releases} <- DeployEx.ReleaseController.list_release_history(app_name, opts[:limit], opts) do
          Mix.shell().info([:green, "\nRelease history for #{app_name}:"])
          Enum.each(releases, fn release ->
            Mix.shell().info([:yellow, "  #{release}"])
          end)
        else
          {:error, %ErrorMessage{code: :not_found}} ->
            Mix.shell().info([:yellow, "No releases found for #{hd(extra_args)}."])

          {:error, err} ->
            Mix.raise("Error fetching releases: #{err}")
        end
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [l: :limit, r: :region, b: :bucket],
      switches: [limit: :integer, region: :string, bucket: :string]
    )
  end
end
