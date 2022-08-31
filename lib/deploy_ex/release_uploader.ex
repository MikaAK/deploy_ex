defmodule DeployEx.ReleaseUploader do
  alias DeployEx.ReleaseUploader.{State, AwsManager, UpdateValidator}

  @type opts :: [
    aws_bucket: String.t,
    aws_region: String.t
  ]

  defdelegate build_state(local_releases, remote_release, git_sha),
    to: State,
    as: :build

  defdelegate reject_unchanged_releases(release_uploader_states),
    to: UpdateValidator,
    as: :reject_unchanged

  def fetch_all_remote_releases(opts) do
    AwsManager.get_releases(opts[:aws_region], opts[:aws_bucket])
  end

  def fetch_all_local_releases do
    case Path.wildcard("./_build/**/*-*.tar.gz") do
      [] -> {:error, ErrorMessage.not_found("no releases found")}
      releases -> {:ok, releases}
    end
  end

  def get_git_sha do
    case System.shell("git rev-parse --short HEAD") do
      {sha, 0} -> {:ok, String.trim_trailing(sha, "\n")}

      {output, code} ->
        {:error, ErrorMessage.failed_dependency(
          "couldn't get the git sha",
          %{code: code, output: output}
        )}
    end
  end

  def app_diffs_since_sha(past_git_sha) do
    case System.shell("git diff --name-only #{past_git_sha}") do
      {diffs, 0} ->
        {:ok, diffs
            |> Enum.split("\n")
            |> Enum.filter(&(&1 =~ ~r/^apps/))
            |> String.replace(~r/^apps\/([a-z_]+)\//, "\\1")}

      {output, code} ->
        {:error, ErrorMessage.failed_dependency(
          "can't lookup diffs with git diff",
          %{code: code, output: output}
        )}
    end
  end

  def upload_release(%State{local_file: local_file, name: remote_file_path}, opts) do
    AwsManager.upload(local_file, opts[:aws_region], opts[:aws_bucket], remote_file_path)
  end
end
