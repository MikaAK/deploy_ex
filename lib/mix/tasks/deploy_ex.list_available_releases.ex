defmodule Mix.Tasks.DeployEx.ListAvailableReleases do
  use Mix.Task

  @shortdoc "Lists all available releases uploaded to the release bucket"
  @moduledoc """
  Lists all available releases found in the configured AWS S3 release bucket.

  ## Example
      mix deploy_ex.list_available_releases
      mix deploy_ex.list_available_releases --app my_app

  ## Options
    * `--app` or `-a` - Filter releases by app name (substring match in release key)
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:ex_aws)

    with :ok <- DeployExHelpers.check_in_umbrella() do
      {opts, _extra_args} = parse_args(args)
      fetch_opts = [
        aws_release_bucket: DeployEx.Config.aws_release_bucket(),
        aws_region: DeployEx.Config.aws_region()
      ]

      case DeployEx.ReleaseUploader.fetch_all_remote_releases(fetch_opts) do
        {:ok, releases} when is_list(releases) and length(releases) > 0 ->
          filtered_releases = if is_nil(opts[:app]) do
            releases
          else
            Enum.filter(releases, &String.contains?(&1, opts[:app]))
          end

          if Enum.empty?(filtered_releases) do
            Mix.shell().info([:yellow, "No releases found for app filter."])
          else
            Mix.shell().info([:green, "\nCurrent releases in bucket:"])
            filtered_releases
              |> Enum.group_by(
                &(&1 |> String.split("/") |> Enum.at(0)),
                &(&1 |> String.split("/") |> Enum.at(1))
              )
              |> Enum.each(fn {app_name, releases} ->
                Mix.shell().info([:yellow, :bright, "\n\n  #{app_name}/"])

                Enum.each(releases, fn release ->
                  Mix.shell().info([:yellow, "    #{release}"])
                end)
              end)
          end
        {:ok, []} ->
          Mix.shell().info([:yellow, "No releases found in the release bucket."])
        {:error, err} ->
          Mix.shell().error([:red, "Error fetching releases: ", to_string(err)])
      end
    end
  end

  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [a: :app],
      switches: [app: :string]
    )
  end
end
