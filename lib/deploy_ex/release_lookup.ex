defmodule DeployEx.ReleaseLookup do
  @moduledoc """
  Centralized release discovery: list remote releases by app + prefix (qa | prod),
  intersect with git-branch history, and resolve a target SHA either interactively
  (TUI.Select prompt) or automatically (newest release).
  """

  require Logger

  @type release :: %{
          sha: String.t(),
          short_sha: String.t(),
          timestamp: integer() | nil,
          key: String.t(),
          prefix: :qa | :prod
        }

  @type release_type :: :qa | :prod
  @type strategy :: :auto | :prompt

  @type opts :: [
          aws_region: String.t() | nil,
          aws_release_bucket: String.t() | nil,
          branch: String.t() | nil,
          git_history_depth: pos_integer(),
          git_impl: module(),
          releases_impl: module()
        ]

  @default_releases_impl DeployEx.ReleaseUploader
  @default_git_impl DeployEx.ReleaseLookup.GitImpl
  @default_git_history_depth 500

  # List remote releases for an app under a prefix (qa/<app>/... or <app>/...).
  # Returns release structs sorted newest-first.
  @spec list_releases(app_name :: String.t(), release_type(), opts()) ::
          {:ok, [release()]} | {:error, ErrorMessage.t()}
  def list_releases(app_name, release_type, opts \\ []) do
    prefix = build_prefix(app_name, release_type)
    fetch_opts = build_fetch_opts(prefix, opts)

    case releases_impl(opts).fetch_all_remote_releases(fetch_opts) do
      {:ok, keys} ->
        releases =
          keys
          |> Enum.map(&parse_release_key(&1, release_type))
          |> Enum.sort_by(&(&1.timestamp || 0), :desc)

        {:ok, releases}

      {:error, _} = error ->
        error
    end
  end

  # Filter releases to those whose SHA appears in the branch's git history.
  # If branch is nil, uses current branch. If git fails, returns the unfiltered list
  # (best-effort: never block the user because git is missing).
  @spec filter_by_branch_history([release()], branch :: String.t() | nil, opts()) ::
          {:ok, [release()]}
  def filter_by_branch_history(releases, branch \\ nil, opts \\ []) do
    depth = Keyword.get(opts, :git_history_depth, @default_git_history_depth)
    effective_branch = branch || "HEAD"

    case git_impl(opts).list_shas_on_branch(effective_branch, depth) do
      {:ok, shas} ->
        sha_set = MapSet.new(shas)
        filtered = Enum.filter(releases, &sha_in_set?(&1, sha_set))
        {:ok, filtered}

      {:error, _} ->
        Logger.debug("#{__MODULE__}: git history unavailable, returning unfiltered releases")
        {:ok, releases}
    end
  end

  # Resolve one SHA for the given app + release_type + strategy.
  # :auto   — pick newest release on current branch (or newest overall if branch filter empty)
  # :prompt — run TUI.Select across branch-filtered releases (user picks one)
  # Returns the full SHA (not short) to match existing SHA usage downstream.
  @spec resolve_sha(app_name :: String.t(), release_type(), strategy(), opts()) ::
          {:ok, String.t()} | {:error, ErrorMessage.t()}
  def resolve_sha(app_name, release_type, strategy, opts \\ []) do
    with {:ok, all_releases} <- list_releases(app_name, release_type, opts),
         {:ok, filtered} <- filter_by_branch_history(all_releases, opts[:branch], opts) do
      pick_release(strategy, filtered, all_releases, app_name, release_type)
    end
  end

  @doc """
  Same as `resolve_sha/4` but searches multiple release types at once (e.g.
  `[:qa, :prod]`). Labels in the interactive picker are prefixed with the type
  so users can see which bucket each release lives in.
  """
  @spec resolve_sha_any(app_name :: String.t(), [release_type()], strategy(), opts()) ::
          {:ok, String.t()} | {:error, ErrorMessage.t()}
  def resolve_sha_any(app_name, release_types, strategy, opts \\ []) when is_list(release_types) do
    with {:ok, all_releases} <- list_releases_multi(app_name, release_types, opts),
         {:ok, filtered} <- filter_by_branch_history(all_releases, opts[:branch], opts) do
      pick_release(strategy, filtered, all_releases, app_name, format_release_types(release_types))
    end
  end

  @doc """
  Same as `resolve_sha_any/4` but runs the interactive picker inside an
  already-open `ExRatatui` terminal instead of opening a new TUI session.

  Use from inside a `DeployEx.TUI.run/1` block when you want to chain pickers
  with a progress screen without tearing the terminal down between steps.
  """
  @spec resolve_sha_any_in_terminal(term(), app_name :: String.t(), [release_type()], strategy(), opts()) ::
          {:ok, String.t()} | {:error, ErrorMessage.t()}
  def resolve_sha_any_in_terminal(terminal, app_name, release_types, strategy, opts \\ [])
      when is_list(release_types) do
    with {:ok, all_releases} <- list_releases_multi(app_name, release_types, opts),
         {:ok, filtered} <- filter_by_branch_history(all_releases, opts[:branch], opts) do
      pick_release_in_terminal(
        terminal,
        strategy,
        filtered,
        all_releases,
        app_name,
        format_release_types(release_types)
      )
    end
  end

  defp pick_release_in_terminal(_terminal, :auto, filtered, all_releases, app_name, release_type) do
    pick_release(:auto, filtered, all_releases, app_name, release_type)
  end

  defp pick_release_in_terminal(_terminal, :prompt, [], [], app_name, release_type) do
    not_found_error(app_name, release_type)
  end

  defp pick_release_in_terminal(terminal, :prompt, [], all_releases, _app_name, release_type) do
    prompt_from_releases_in_terminal(terminal, all_releases, "Select #{release_type} release (any branch)")
  end

  defp pick_release_in_terminal(terminal, :prompt, [_single], [_, _ | _] = all_releases, _app_name, release_type) do
    prompt_from_releases_in_terminal(terminal, all_releases, "Select #{release_type} release (any branch)")
  end

  defp pick_release_in_terminal(terminal, :prompt, [_single] = filtered, _all_releases, _app_name, release_type) do
    prompt_from_releases_in_terminal(terminal, filtered, "Select #{release_type} release")
  end

  defp pick_release_in_terminal(terminal, :prompt, releases, _all_releases, _app_name, release_type) do
    prompt_from_releases_in_terminal(terminal, releases, "Select #{release_type} release")
  end

  defp prompt_from_releases_in_terminal(terminal, releases, title) do
    labels = Enum.map(releases, &format_release_label/1)

    case DeployEx.TUI.Select.run_in_terminal(terminal, labels, title: title, always_prompt: true) do
      [] ->
        {:error, ErrorMessage.bad_request("no release selected")}

      [chosen_label] ->
        sha = find_sha_for_label(releases, labels, chosen_label)
        {:ok, sha}
    end
  end

  defp list_releases_multi(app_name, release_types, opts) do
    fetched =
      Enum.reduce_while(release_types, {:ok, []}, fn type, {:ok, acc} ->
        case list_releases(app_name, type, opts) do
          {:ok, releases} -> {:cont, {:ok, acc ++ releases}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case fetched do
      {:ok, releases} -> {:ok, Enum.sort_by(releases, &(&1.timestamp || 0), :desc)}
      {:error, _} = error -> error
    end
  end

  defp format_release_types(types), do: Enum.map_join(types, "/", &to_string/1)

  # PRIVATE

  defp releases_impl(opts), do: Keyword.get(opts, :releases_impl, @default_releases_impl)
  defp git_impl(opts), do: Keyword.get(opts, :git_impl, @default_git_impl)

  defp build_prefix(app_name, :qa), do: "qa/#{app_name}/"
  defp build_prefix(app_name, :prod), do: "#{app_name}/"

  defp build_fetch_opts(prefix, opts) do
    [
      aws_region: opts[:aws_region] || DeployEx.Config.aws_region(),
      aws_release_bucket: opts[:aws_release_bucket] || DeployEx.Config.aws_release_bucket(),
      prefix: prefix
    ]
  end

  defp parse_release_key(key, release_type) do
    sha = DeployExHelpers.extract_sha_from_release(key)
    timestamp = extract_timestamp(key)
    short_sha = extract_short_sha(sha)

    %{
      sha: sha,
      short_sha: short_sha,
      timestamp: timestamp,
      key: key,
      prefix: release_type
    }
  end

  defp extract_timestamp(key) do
    case String.split(Path.basename(key), "-") do
      [ts | _] ->
        case Integer.parse(ts) do
          {unix_ts, ""} -> unix_ts
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_short_sha(nil), do: nil
  defp extract_short_sha(sha), do: String.slice(sha, 0, 7)

  defp sha_in_set?(%{short_sha: short_sha}, sha_set) when not is_nil(short_sha) do
    Enum.any?(sha_set, fn history_sha ->
      String.starts_with?(short_sha, history_sha) or
        String.starts_with?(history_sha, short_sha)
    end)
  end

  defp sha_in_set?(_, _), do: false

  defp pick_release(:auto, [], all_releases, app_name, release_type) do
    pick_auto(all_releases, app_name, release_type)
  end

  defp pick_release(:auto, filtered, _all_releases, _app_name, _release_type) do
    {:ok, hd(filtered).sha}
  end

  defp pick_release(:prompt, [], [], app_name, release_type) do
    not_found_error(app_name, release_type)
  end

  defp pick_release(:prompt, [], all_releases, _app_name, release_type) do
    prompt_from_releases(all_releases, "Select #{release_type} release (any branch)")
  end

  defp pick_release(:prompt, [_single], [_, _ | _] = all_releases, _app_name, release_type) do
    prompt_from_releases(all_releases, "Select #{release_type} release (any branch)")
  end

  defp pick_release(:prompt, [single], _all_releases, _app_name, _release_type) do
    {:ok, single.sha}
  end

  defp pick_release(:prompt, releases, _all_releases, _app_name, release_type) do
    prompt_from_releases(releases, "Select #{release_type} release")
  end

  defp prompt_from_releases(releases, title) do
    labels = Enum.map(releases, &format_release_label/1)

    case DeployEx.TUI.Select.run(labels, title: title) do
      [] ->
        {:error, ErrorMessage.bad_request("no release selected")}

      [chosen_label] ->
        sha = find_sha_for_label(releases, labels, chosen_label)
        {:ok, sha}
    end
  end

  defp pick_auto([], app_name, release_type) do
    not_found_error(app_name, release_type)
  end

  defp pick_auto([newest | _], _app_name, _release_type) do
    {:ok, newest.sha}
  end

  defp not_found_error(app_name, release_type) do
    {:error,
     ErrorMessage.not_found(
       "no #{release_type} releases found for #{app_name}",
       %{app_name: app_name, release_type: release_type}
     )}
  end

  defp format_release_label(%{short_sha: short_sha, timestamp: timestamp, key: key, prefix: prefix}) do
    humanized = humanize_timestamp(timestamp)
    "[#{prefix}]  #{short_sha}  #{humanized}  (#{key})"
  end

  defp find_sha_for_label(releases, labels, chosen_label) do
    index = Enum.find_index(labels, &(&1 === chosen_label))
    Enum.at(releases, index).sha
  end

  defp humanize_timestamp(nil), do: "unknown date"

  defp humanize_timestamp(unix_ts) do
    case DateTime.from_unix(unix_ts) do
      {:ok, datetime} -> humanize_datetime(datetime)
      _ -> to_string(unix_ts)
    end
  end

  defp humanize_datetime(datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86_400)} days ago"
      true -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
    end
  end
end
