defmodule Mix.Tasks.DeployEx.ViewCurrentRelease do
  use Mix.Task

  @shortdoc "Shows the current (latest) release for a specific app from S3"
  @moduledoc """
  Shows the current (latest) release for the specified app by fetching from S3.

  ## Example
      mix deploy_ex.view_current_release my_app

  ## Options
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

      if extra_args === [] do
        Mix.raise("app_name is required. Example: mix deploy_ex.view_current_release my_app")
      else
        with {:ok, app_name} <- DeployExHelpers.find_project_name(extra_args),
             {:ok, current_release} <- DeployEx.ReleaseController.fetch_current_release(app_name, opts) do
          Mix.shell().info([:green, "\nCurrent release for #{app_name}:\n  ", :yellow, current_release])
        else
          {:error, %ErrorMessage{code: :not_found}} ->
            Mix.shell().info([:yellow, "No release found for #{hd(extra_args)}."])

          {:error, err} ->
            Mix.raise("Error fetching current release: #{err}")
        end
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [r: :region, b: :bucket],
      switches: [region: :string, bucket: :string]
    )
  end
end
