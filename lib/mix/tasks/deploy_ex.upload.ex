defmodule Mix.Tasks.DeployEx.Upload do
  use Mix.Task

  alias DeployEx.{ReleaseUploader, Config}

  @default_aws_region Config.aws_release_region()
  @default_aws_bucket Config.aws_release_bucket()

  @shortdoc "Uploads your release folder to Amazon S3"
  @moduledoc """
  Uploads your release to AWS S3 into a bucket

  This is organised by release and will store the last 10 releases
  by date/time, as well as marks them with the Github Sha. By doing this
  you can run `mix ansible.rollback <sha>` or `mix ansible.rollback` to rollback
  either to a specific sha, or to the last previous release

  After uploading your release, you can deploy it to all servers by calling
  `mix ansible.build`, before building make sure nodes are setup using `mix ansible.setup_nodes`

  ## Options

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
         {:ok, local_releases} <- ReleaseUploader.fetch_all_local_releases(),
         {:ok, remote_releases} <- ReleaseUploader.fetch_all_remote_releases(opts),
         {:ok, git_sha} <- ReleaseUploader.get_git_sha() do
      {has_previous_upload_release_cands, no_prio_upload_release_cands} = local_releases
        |> ReleaseUploader.build_state(remote_releases, git_sha)
        |> IO.inspect
        |> Enum.reject(&already_uploaded?/1)
        |> IO.inspect
        |> Enum.split_with(&(&1.last_sha))

      case upload_releases(no_prio_upload_release_cands, opts) do
        {:ok, _} -> upload_changed_releases(has_previous_upload_release_cands, opts)
        {:error, e} -> Mix.raise(to_string(e))
      end
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quit],
      switches: [
        force: :boolean,
        quiet: :boolean,
        aws_region: :string,
        aws_bucket: :string
      ]
    )

    opts
  end

  def already_uploaded?(%ReleaseUploader.State{
    remote_file: remote_file,
    local_file: local_file
  }) do
    if is_nil(remote_file) do
      false
    else
      Mix.shell.info([:yellow, "* skipping already uploaded release ", :reset, local_file])

      true
    end
  end

  defp upload_changed_releases(release_candidates, opts) do
    case ReleaseUploader.reject_unchanged_releases(release_candidates) do
      {:ok, []} ->
        log_unchanged_releases(release_candidates)

      {:ok, final_release_candidates} ->
        log_unchanged_releases(release_candidates -- final_release_candidates)

        upload_releases(final_release_candidates, opts)

      {:error, %ErrorMessage{code: :not_found}} ->
        log_unchanged_releases(release_candidates)

      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp log_unchanged_releases(release_candidates) do
    Enum.each(release_candidates, &Mix.shell().info([
      :yellow, "* skipping unchanged release ",
      :reset, &1.local_file
    ]))
  end

  defp upload_releases(release_candidates, opts) do
    release_candidates
      |> Enum.map(&upload_release(&1, opts))
      |> DeployEx.Utils.reduce_status_tuples
  end

  defp upload_release(%ReleaseUploader.State{} = release_state, opts) do
    Mix.shell.info([:green, "* uploading to S3 ", :reset, release_state.local_file])

    case ReleaseUploader.upload_release(release_state, opts) do
      {:ok, _} = res ->
        Mix.shell.info([
          :green, "* uploaded to S3 ", :reset,
          release_state.local_file, :green, " as ", :reset,
          release_state.name
        ])

        res

      {:error, e} ->
        Mix.shell().error(to_string(e))

        e
    end
  end
end
