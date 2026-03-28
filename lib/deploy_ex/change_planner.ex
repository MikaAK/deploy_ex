defmodule DeployEx.ChangePlanner do
  @moduledoc """
  Compares a rendered upstream directory against the user's deploy directory
  and produces a typed list of actions describing what changed.
  Detects renames, splits, and merges via content similarity.
  """

  @type action ::
          {:identical, String.t()}
          | {:update, upstream_path :: String.t(), user_path :: String.t()}
          | {:rename, upstream_path :: String.t(), user_path :: String.t()}
          | {:split, upstream_path :: String.t(), [user_path :: String.t()]}
          | {:merge_files, [upstream_path :: String.t()], user_path :: String.t()}
          | {:new, upstream_path :: String.t()}
          | {:removed, upstream_path :: String.t()}
          | {:user_only, user_path :: String.t()}

  @similarity_high 0.8
  @similarity_split 0.65
  @similarity_moderate 0.4
  @large_file_bytes 50_000
  @chunk_size 500

  @action_sort_order %{
    identical: 0,
    update: 1,
    rename: 2,
    split: 3,
    merge_files: 4,
    new: 5,
    removed: 6,
    user_only: 7
  }

  # SECTION: Public API

  @spec plan(String.t(), String.t(), keyword()) :: {:ok, [action()]} | {:error, ErrorMessage.t()}
  def plan(rendered_dir, deploy_folder, opts \\ []) do
    with {:ok, upstream_files} <- list_files(rendered_dir),
         {:ok, user_files} <- list_files(deploy_folder) do
      upstream_set = MapSet.new(upstream_files)
      user_set = MapSet.new(user_files)

      exact_matches = MapSet.intersection(upstream_set, user_set)
      upstream_only = upstream_set |> MapSet.difference(user_set) |> MapSet.to_list()
      user_only = user_set |> MapSet.difference(upstream_set) |> MapSet.to_list()

      exact_actions = classify_exact_matches(exact_matches, rendered_dir, deploy_folder)
      {matched_actions, remaining_upstream, remaining_user} =
        match_unmatched(upstream_only, user_only, rendered_dir, deploy_folder, opts)

      new_actions = Enum.map(remaining_upstream, &{:new, &1})
      user_only_actions = Enum.map(remaining_user, &{:user_only, &1})

      actions =
        (exact_actions ++ matched_actions ++ new_actions ++ user_only_actions)
        |> sort_actions()

      {:ok, actions}
    end
  end

  # SECTION: File Listing

  defp list_files(dir) do
    if File.dir?(dir) do
      files =
        dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, dir))
        |> Enum.reject(&skip_file?/1)

      {:ok, files}
    else
      {:error, ErrorMessage.not_found("Directory not found: #{dir}")}
    end
  end

  defp skip_file?(relative_path) do
    basename = Path.basename(relative_path)

    String.starts_with?(basename, ".") or String.ends_with?(basename, ".md")
  end

  # SECTION: Exact Path Matching

  defp classify_exact_matches(matches, rendered_dir, deploy_folder) do
    matches
    |> Enum.map(fn path ->
      upstream_content = File.read!(Path.join(rendered_dir, path))
      user_content = File.read!(Path.join(deploy_folder, path))

      if upstream_content === user_content do
        {:identical, path}
      else
        {:update, path, path}
      end
    end)
  end

  # SECTION: Similarity Matching

  defp match_unmatched(upstream_only, user_only, rendered_dir, deploy_folder, opts) do
    upstream_contents =
      Map.new(upstream_only, fn path ->
        {path, File.read!(Path.join(rendered_dir, path))}
      end)

    user_contents =
      Map.new(user_only, fn path ->
        {path, File.read!(Path.join(deploy_folder, path))}
      end)

    # For each upstream-only file, compute similarity against all user-only files
    similarity_matrix =
      for {up_path, up_content} <- upstream_contents,
          {usr_path, usr_content} <- user_contents,
          into: %{} do
        {{up_path, usr_path}, content_similarity(up_content, usr_content)}
      end

    {actions, claimed_upstream, claimed_user} =
      resolve_matches(upstream_only, user_only, similarity_matrix, opts)

    remaining_upstream = Enum.reject(upstream_only, &(&1 in claimed_upstream))
    remaining_user = Enum.reject(user_only, &(&1 in claimed_user))

    {actions, remaining_upstream, remaining_user}
  end

  defp resolve_matches(upstream_only, user_only, similarity_matrix, opts) do
    # First pass: find high-similarity rename candidates
    # For each upstream file, collect user files with high similarity
    upstream_matches =
      Enum.map(upstream_only, fn up_path ->
        high_matches =
          user_only
          |> Enum.map(fn usr_path ->
            {usr_path, Map.get(similarity_matrix, {up_path, usr_path}, 0.0)}
          end)
          |> Enum.filter(fn {_path, sim} -> sim >= @similarity_high end)
          |> Enum.sort_by(fn {_path, sim} -> sim end, :desc)

        split_matches =
          user_only
          |> Enum.map(fn usr_path ->
            {usr_path, Map.get(similarity_matrix, {up_path, usr_path}, 0.0)}
          end)
          |> Enum.filter(fn {_path, sim} -> sim >= @similarity_split end)
          |> Enum.sort_by(fn {_path, sim} -> sim end, :desc)

        {up_path, high_matches, split_matches}
      end)

    {actions, claimed_upstream, claimed_user} =
      Enum.reduce(upstream_matches, {[], MapSet.new(), MapSet.new()}, fn
        {up_path, high_matches, split_matches}, {acc_actions, acc_up, acc_usr} ->
          available_split = Enum.reject(split_matches, fn {usr_path, _} -> usr_path in acc_usr end)
          available_high = Enum.reject(high_matches, fn {usr_path, _} -> usr_path in acc_usr end)

          cond do
            # Multiple files with split-level similarity -> split
            length(available_split) >= 2 and length(available_high) >= 1 ->
              user_paths = Enum.map(available_split, fn {path, _} -> path end)
              action = {:split, up_path, user_paths}
              claimed = Enum.reduce(user_paths, acc_usr, &MapSet.put(&2, &1))
              {[action | acc_actions], MapSet.put(acc_up, up_path), claimed}

            # Exactly one high-similarity match -> rename
            length(available_high) === 1 ->
              [{usr_path, _sim}] = available_high
              action = {:rename, up_path, usr_path}
              {[action | acc_actions], MapSet.put(acc_up, up_path), MapSet.put(acc_usr, usr_path)}

            # Multiple high-similarity matches but no split -> split from high only
            length(available_high) >= 2 ->
              user_paths = Enum.map(available_high, fn {path, _} -> path end)
              action = {:split, up_path, user_paths}
              claimed = Enum.reduce(user_paths, acc_usr, &MapSet.put(&2, &1))
              {[action | acc_actions], MapSet.put(acc_up, up_path), claimed}

            true ->
              {acc_actions, acc_up, acc_usr}
          end
      end)

    # Second pass: moderate similarity with LLM disambiguation
    remaining_upstream = Enum.reject(upstream_only, &(&1 in claimed_upstream))
    remaining_user = Enum.reject(user_only, &(&1 in claimed_user))

    {llm_actions, llm_claimed_up, llm_claimed_usr} =
      resolve_moderate_matches(remaining_upstream, remaining_user, similarity_matrix, opts)

    final_actions = actions ++ llm_actions
    final_claimed_up = MapSet.union(claimed_upstream, llm_claimed_up)
    final_claimed_usr = MapSet.union(claimed_user, llm_claimed_usr)

    {final_actions, final_claimed_up, final_claimed_usr}
  end

  defp resolve_moderate_matches(upstream_only, user_only, similarity_matrix, opts) do
    llm_provider = Keyword.get(opts, :llm_provider)

    if is_nil(llm_provider) do
      {[], MapSet.new(), MapSet.new()}
    else
      Enum.reduce(upstream_only, {[], MapSet.new(), MapSet.new()}, fn
        up_path, {acc_actions, acc_up, acc_usr} ->
          candidates =
            user_only
            |> Enum.reject(&(&1 in acc_usr))
            |> Enum.map(fn usr_path ->
              {usr_path, Map.get(similarity_matrix, {up_path, usr_path}, 0.0)}
            end)
            |> Enum.filter(fn {_path, sim} ->
              sim >= @similarity_moderate and sim < @similarity_high
            end)
            |> Enum.sort_by(fn {_path, sim} -> sim end, :desc)

          case candidates do
            [{usr_path, _sim} | _] ->
              if llm_confirms_rename?(up_path, usr_path, opts) do
                action = {:rename, up_path, usr_path}
                {[action | acc_actions], MapSet.put(acc_up, up_path), MapSet.put(acc_usr, usr_path)}
              else
                {acc_actions, acc_up, acc_usr}
              end

            [] ->
              {acc_actions, acc_up, acc_usr}
          end
      end)
    end
  end

  # SECTION: Content Similarity

  defp content_similarity(content_a, content_b) do
    chunk_a = similarity_chunk(content_a)
    chunk_b = similarity_chunk(content_b)

    String.jaro_distance(chunk_a, chunk_b)
  end

  defp similarity_chunk(content) do
    byte_size = byte_size(content)

    cond do
      byte_size > @large_file_bytes ->
        String.slice(content, 0, 1000)

      byte_size > @chunk_size * 2 ->
        first = String.slice(content, 0, @chunk_size)
        last = String.slice(content, -@chunk_size, @chunk_size)
        first <> last

      true ->
        content
    end
  end

  # SECTION: LLM Disambiguation

  defp llm_confirms_rename?(upstream_path, user_path, opts) do
    llm_provider = Keyword.get(opts, :llm_provider)

    prompt = """
    Is the file "#{user_path}" a renamed/restructured version of "#{upstream_path}"?
    Answer only "yes" or "no".
    """

    case DeployEx.LLMMerge.ask(prompt, llm_provider: llm_provider) do
      {:ok, response} ->
        response
        |> String.downcase()
        |> String.trim()
        |> String.contains?("yes")

      {:error, _} ->
        false
    end
  end

  # SECTION: Sorting

  defp sort_actions(actions) do
    Enum.sort_by(actions, fn action ->
      type = elem(action, 0)
      Map.get(@action_sort_order, type, 99)
    end)
  end
end
