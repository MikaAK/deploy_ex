defmodule DeployEx.ReleaseUploader.State do
  @enforce_keys [:local_file, :sha, :app_name]
  defstruct @enforce_keys ++ [:name, :last_sha, :remote_file, :release_apps]


  def build(local_releases, remote_releases, git_sha, opts \\ []) do
    {:ok, release_apps_map} = DeployExHelpers.release_apps_by_release_name()
    release_prefix = release_prefix(opts)

    Enum.map(local_releases, fn release_file_path ->
      app_name = app_name_from_local_release_file(release_file_path)
      remote_file = find_remote_release(remote_releases, app_name, git_sha, release_prefix)

      %DeployEx.ReleaseUploader.State{
        app_name: app_name,
        local_file: release_file_path,
        sha: git_sha,
        name: remote_file_name_for_release(release_file_path, git_sha, release_prefix),
        remote_file: remote_file,
        last_sha: last_sha_from_remote_file(remote_releases, app_name, release_prefix),
        release_apps: release_apps_map[String.to_atom(app_name)]
      }
    end)
  end

  defp find_remote_release(remote_release_paths, app_name, git_sha, release_prefix) do
    path_prefix = release_path_prefix(app_name, release_prefix)

    Enum.find(remote_release_paths, fn path ->
      String.starts_with?(path, path_prefix) and String.contains?(path, "#{git_sha}")
    end)
  end

  defp remote_file_name_for_release(release_file_path, git_sha, release_prefix) do
    current_timestamp = DateTime.utc_now() |> DateTime.to_unix
    file_name = Path.basename(release_file_path)
    app_name = app_name_from_local_release_file(release_file_path)
    path_prefix = release_path_prefix(app_name, release_prefix)

    "#{path_prefix}#{current_timestamp}-#{git_sha}-#{file_name}"
  end

  defp app_name_from_local_release_file(release_file_path) do
    file_name = Path.basename(release_file_path)
    [app_name | _] = String.split(file_name, "-")

    app_name
  end

  def lastest_remote_app_release(remote_releases, app_name, release_prefix \\ nil) do
    path_prefix = release_path_prefix(app_name, release_prefix)

    remote_releases
      |> Enum.filter(&String.starts_with?(&1, path_prefix))
      |> Enum.map(fn release_path ->
        base_name = Path.basename(release_path)
        [timestamp, git_sha, ^app_name, _] = String.split(base_name, "-")

        {String.to_integer(timestamp), git_sha, base_name}
      end)
      |> Enum.sort_by(fn {timestamp, _, _} -> timestamp end, :desc)
      |> List.first
  end

  def last_sha_from_remote_file(remote_releases, app_name, release_prefix) do
    case lastest_remote_app_release(remote_releases, app_name, release_prefix) do
      {_, sha, _} -> sha
      nil -> nil
    end
  end

  defp release_prefix(opts) when is_map(opts) do
    release_prefix(Map.to_list(opts))
  end

  defp release_prefix(opts) when is_list(opts) do
    case Keyword.get(opts, :release_prefix) do
      prefix when is_binary(prefix) and prefix !== "" -> prefix
      _ -> if Keyword.get(opts, :qa_release) === true, do: "qa", else: nil
    end
  end

  defp release_path_prefix(app_name, nil), do: "#{app_name}/"
  defp release_path_prefix(app_name, ""), do: "#{app_name}/"
  defp release_path_prefix(app_name, release_prefix), do: "#{release_prefix}/#{app_name}/"
end
