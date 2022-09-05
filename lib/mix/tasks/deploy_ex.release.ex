defmodule Mix.Tasks.DeployEx.Release do
  use Mix.Task

  alias DeployEx.{ReleaseUploader, Config}

  @default_aws_region Config.aws_release_region()
  @default_aws_bucket Config.aws_release_bucket()
  @max_build_concurrency 6

  @shortdoc "Runs mix.release for apps that have changed"
  @moduledoc """
  This command checks AWS S3 for the current releases and checks
  if there are any changes in git between the current branch and
  current release. If there are changes in direct app code,
  inner umbrella dependency code changes or dep changes in the mix.lock
  that are connected to your app, the release will run, otherwise it will
  ignore it

  This command also correctly detects phoenix applications, and if found will
  run `mix assets.deploy` in those apps

  ## Options

  - `force` - Force overwrite (alias: `f`)
  - `quiet` - Force overwrite (alias: `q`)
  - `recompile` - Force recompile (alias: `r`)
  - `aws-region` - Region for aws (default: `#{@default_aws_region}`)
  - `aws-bucket` - Region for aws (default: `#{@default_aws_bucket}`)
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)

    opts = args
      |> parse_args
      |> Keyword.put(:aws_bucket, Config.aws_release_bucket())
      |> Keyword.put(:aws_region, Config.aws_release_region())

    with :ok <- DeployExHelpers.check_in_umbrella(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
         {:ok, remote_releases} <- ReleaseUploader.fetch_all_remote_releases(opts),
         {:ok, git_sha} <- ReleaseUploader.get_git_sha() do
      releases = Keyword.keys(releases)

      {
        has_previous_upload_release_cands,
        no_prio_upload_release_cands
      } = releases
        |> Enum.map(&to_string/1)
        |> ReleaseUploader.build_state(remote_releases, git_sha)
        |> Enum.reject(&Mix.Tasks.DeployEx.Upload.already_uploaded?/1)
        |> Enum.split_with(&(&1.last_sha))

      tasks = [
        Task.async(fn -> run_initial_release(no_prio_upload_release_cands, opts) end),
        Task.async(fn -> run_update_releases(has_previous_upload_release_cands, opts) end)
      ]

      res = tasks
        |> Enum.map(&Task.await(&1, :timer.seconds(60)))
        |> DeployEx.Utils.reduce_status_tuples

      case res do
        {:error, [h | tail]} ->
          Enum.each(tail, &Mix.shell().error("Error with releasing #{inspect(&1, pretty: true)}"))

          Mix.raise(inspect(h, pretty: true))

        {:ok, _} ->
          Mix.shell().info([:green, "Successfuly built ", :reset, Enum.join(releases, ", ")])
      end
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit, r: :recompile],
      switches: [
        force: :boolean,
        quiet: :boolean,
        recompile: :boolean,
        aws_region: :string,
        aws_bucket: :string
      ]
    )

    opts
  end

  defp run_initial_release(release_candidates, opts) do
    release_candidates
      |> Task.async_stream(fn %ReleaseUploader.State{} = candidate ->
        Mix.shell().info([
          :green, "* running initial release for ",
          :reset, candidate.local_file
        ])

        run_mix_release(candidate, opts)
      end, timeout: :timer.seconds(60), max_concurrency: div(@max_build_concurrency, 2))
      |> DeployEx.Utils.reduce_task_status_tuples
  end

  defp run_update_releases(release_candidates, opts) do
    release_candidates
      |> Task.async_stream(fn %ReleaseUploader.State{} = candidate ->
        Mix.shell().info([
          :green, "* running release to update ",
          :reset, candidate.local_file
        ])

        run_mix_release(candidate, opts)
      end, timeout: :timer.seconds(60), max_concurrency: div(@max_build_concurrency, 2))
      |> DeployEx.Utils.reduce_task_status_tuples
  end

  defp run_mix_release(%ReleaseUploader.State{app_name: app_name} = candidate, opts) do
    args = Enum.reduce(opts, [], fn
      {:force, true}, acc -> ["--overwrite" | acc]
      {:recompile, true}, acc -> ["--force" | acc]
      {:quiet, true}, acc -> ["--quiet" | acc]
      _, acc -> acc
    end)

    case Mix.Tasks.Release.run([app_name | args]) do
      :ok -> {:ok, candidate}
      {:error, reason} -> {:ok, ErrorMessage.failed_dependency("mix release failed", %{reason: reason})}
    end
  end
end


