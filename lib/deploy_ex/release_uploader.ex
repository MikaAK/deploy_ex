defmodule DeployEx.ReleaseUploader do
  alias DeployEx.ReleaseUploader.{State, AwsManager, UpdateValidator}

  @type opts :: [
    aws_release_bucket: String.t,
    aws_region: String.t,
    qa_release: boolean
  ]

  @qa_tag_key "qa"
  @qa_tag_value "true"

  def lastest_app_release(remote_releases, app_names) when is_list(app_names) do
    app_names
      |> Enum.map(fn app_name ->
        with {:ok, release_name} <- lastest_app_release(remote_releases, app_name) do
          {:ok, {app_name, release_name}}
        end
      end)
      |> DeployEx.Utils.reduce_status_tuples
      |> then(fn
        {:ok, app_releases} -> {:ok, Map.new(app_releases)}
        e -> e
      end)
  end

  def lastest_app_release(remote_releases, app_name) do
    case State.lastest_remote_app_release(remote_releases, app_name) do
      {_timestamp, _sha, file_name} -> {:ok, file_name}
      nil ->
        {:error, ErrorMessage.not_found(
          "no release found for #{app_name}",
          %{releases: remote_releases}
        )}
    end
  end

  defdelegate build_state(local_releases, remote_release, git_sha),
    to: State,
    as: :build

  defdelegate filter_changed_releases(release_uploader_states),
    to: UpdateValidator,
    as: :filter_changed

  defdelegate app_dep_tree,
    to: UpdateValidator.MixDepsTreeParser,
    as: :load_app_dep_tree

  def fetch_all_remote_releases(opts) do
    AwsManager.get_releases(opts[:aws_region], opts[:aws_release_bucket])
  end

  def fetch_all_local_releases do
    case Path.wildcard("./_build/*/*-*.tar.gz") do
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

  def upload_release(%State{local_file: local_file, name: remote_file_path}, opts) do
    case AwsManager.upload(
           local_file,
           opts[:aws_region],
           opts[:aws_release_bucket],
           remote_file_path
         ) do
      {:ok, _} = res ->
        with :ok <- maybe_tag_release(remote_file_path, opts) do
          res
        end

      :ok ->
        with :ok <- maybe_tag_release(remote_file_path, opts) do
          {:ok, :done}
        end

      {:error, _} = error ->
        error
    end
  end

  def get_git_branch do
    case System.shell("git rev-parse --abbrev-ref HEAD") do
      {branch, 0} -> {:ok, String.trim_trailing(branch, "\n")}

      {output, code} ->
        {:error, ErrorMessage.failed_dependency(
          "couldn't get the git branch",
          %{code: code, output: output}
        )}
    end
  end

  defp maybe_tag_release(remote_file_path, opts) when is_map(opts) do
    maybe_tag_release(remote_file_path, Map.to_list(opts))
  end

  defp maybe_tag_release(remote_file_path, opts) when is_list(opts) do
    case Keyword.get(opts, :qa_release) do
      true ->
        aws_region = Keyword.get(opts, :aws_region)
        aws_release_bucket = Keyword.get(opts, :aws_release_bucket)

        aws_region
          |> AwsManager.tag_object(
            aws_release_bucket,
            remote_file_path,
            %{@qa_tag_key => @qa_tag_value}
          )
          |> case do
            :ok -> :ok
            {:ok, _} -> :ok
            {:error, _} = error -> error
          end

      _ ->
        :ok
    end
  end
end
