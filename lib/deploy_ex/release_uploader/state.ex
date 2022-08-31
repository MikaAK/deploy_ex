defmodule DeployEx.ReleaseUploader.State do
  @enforce_keys [:local_file, :sha, :app_name]
  defstruct @enforce_keys ++ [:name, :last_sha, :remote_file]

  def build(local_releases, remote_releases, git_sha) do
    Enum.map(local_releases, fn release_file_path ->
      app_name = app_name_from_local_release_file(release_file_path)
      remote_file = find_remote_release(remote_releases, app_name, git_sha)

      %DeployEx.ReleaseUploader.State{
        app_name: app_name,
        local_file: release_file_path,
        sha: git_sha,
        name: remote_file_name_for_release(release_file_path, git_sha),
        remote_file: remote_file,
        last_sha: last_sha_from_remote_file(remote_releases, app_name)
      }
    end)
  end

  defp find_remote_release(remote_release_paths, app_name, git_sha) do
    Enum.find(remote_release_paths, fn path ->
      path =~ ~r/#{app_name}\/\d+-#{git_sha}/
    end)
  end

  defp remote_file_name_for_release(release_file_path, git_sha) do
    current_timestamp = DateTime.utc_now() |> DateTime.to_unix
    file_name = Path.basename(release_file_path)
    app_name = app_name_from_local_release_file(release_file_path)

    "#{app_name}/#{current_timestamp}-#{git_sha}-#{file_name}"
  end

  defp app_name_from_local_release_file(release_file_path) do
    file_name = Path.basename(release_file_path)
    [app_name | _] = String.split(file_name, "-")

    app_name
  end

  def lastest_remote_app_release(remote_releases, app_name) do
    remote_releases
      |> Enum.filter(&(&1 =~ ~r/^#{app_name}\//))
      |> Enum.map(fn release_path ->
        base_name = Path.basename(release_path)
        [timestamp, git_sha, ^app_name, _] = String.split(base_name, "-")

        {String.to_integer(timestamp), git_sha, base_name}
      end)
      |> Enum.sort_by(fn {timestamp, _, _} -> timestamp end, :desc)
      |> List.first
  end

  def last_sha_from_remote_file(remote_releases, app_name) do
    case lastest_remote_app_release(remote_releases, app_name) do
      {_, sha, _} -> sha
      nil -> nil
    end
  end
end
