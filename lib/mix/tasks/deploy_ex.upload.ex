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

    opts = args
      |> parse_args
      |> Keyword.put(:aws_bucket, Config.aws_release_bucket())
      |> Keyword.put(:aws_region, Config.aws_release_region())

    with {:ok, local_releases} <- ReleaseUploader.fetch_all_local_releases(),
         {:ok, remote_releases} <- ReleaseUploader.fetch_all_remote_releases(opts),
         {:ok, git_sha} <- ReleaseUploader.get_git_sha() do
      local_releases
        |> ReleaseUploader.State.build(remote_releases, git_sha)
        |> Enum.reject(&already_uploaded?/1)
        |> Enum.map(&upload_release(&1, opts))
    else
      {:error, e} -> Mix.shell().error(to_string(e))
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

  defp already_uploaded?(%ReleaseUploader.State{remote_file: remote_file, local_file: local_file}) do
    if not is_nil(remote_file) do
      Mix.shell.info([:yellow, "* skipping already uploaded file ", :reset, local_file])

      true
    end
  end

  defp upload_release(%ReleaseUploader.State{} = release_state, opts) do
    Mix.shell.info([:green, "* uploading to S3 ", :reset, release_state.local_file])

    with {:ok, _} = res <- ReleaseUploader.upload_release(release_state, opts) do
      Mix.shell.info([
        :green, "* uploaded to S3 ", :reset,
        release_state.local_file, :green, " as ", :reset,
        release_state.name
      ])

      res
    end
  end
end
