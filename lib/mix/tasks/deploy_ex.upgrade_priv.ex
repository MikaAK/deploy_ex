defmodule Mix.Tasks.DeployEx.UpgradePriv do
  use Mix.Task

  @shortdoc "Upgrades ./deploys/ from the latest deploy_ex templates"
  @moduledoc """
  Compares rendered upstream templates against your `./deploys/` directory
  and applies changes interactively, with AI review, or autonomously.

  The upgrade pipeline:
  1. Renders all priv EEx templates to a temp directory (same as terraform.build/ansible.build)
  2. Compares rendered output against your existing `./deploys/` files
  3. Creates a backup of all files that will be modified
  4. Applies changes according to the selected mode

  ## Modes

  **Interactive (default):** Category summary, drill into each category,
  hunk-level accept/reject for updates via DiffViewer.

  **AI-assisted (`--ai-review`):** LLM reviews each change and proposes
  accept/reject per file. You confirm before any writes.

  **Autonomous (`--llm-merge`):** LLM applies all changes automatically.
  Summary shown at the end. Files can be restored from backup.

  ## Examples

      mix deploy_ex.upgrade_priv
      mix deploy_ex.upgrade_priv --ai-review
      mix deploy_ex.upgrade_priv --llm-merge

  ## Options

  - `--ai-review` - LLM reviews diffs and proposes a plan; you confirm per file
  - `--llm-merge` - LLM applies all changes autonomously
  """

  require Logger

  # SECTION: Public API

  @spec run(list(String.t())) :: :ok
  def run(args) do
    opts = parse_args(args)
    deploy_folder = DeployEx.Config.deploy_folder()

    if opts[:llm_merge] or opts[:ai_review] do
      Application.ensure_all_started(:telemetry)
      Application.ensure_all_started(:req)
    end

    with :ok <- DeployExHelpers.check_valid_project(),
         {:ok, temp_dir, actions} <- run_pipeline(deploy_folder, opts) do
      try do
        backup_dir = create_backup(actions, deploy_folder)

        cond do
          opts[:llm_merge] -> run_autonomous(actions, temp_dir, deploy_folder, backup_dir)
          opts[:ai_review] -> run_ai_assisted(actions, temp_dir, deploy_folder, backup_dir)
          true -> run_interactive(actions, temp_dir, deploy_folder, backup_dir)
        end

        update_manifest(deploy_folder)
      after
        File.rm_rf!(temp_dir)
      end
    else
      {:error, %ErrorMessage{} = error} -> Mix.raise(ErrorMessage.to_string(error))
      {:error, reason} -> Mix.raise("Upgrade failed: #{inspect(reason)}")
    end
  end

  # SECTION: Shared Pipeline

  defp run_pipeline(deploy_folder, opts) do
    Mix.shell().info([:cyan, "* rendering upstream templates..."])

    with {:ok, temp_dir} <- DeployEx.PrivRenderer.render_to_temp(opts) do
      Mix.shell().info([:cyan, "* planning changes..."])

      case DeployEx.ChangePlanner.plan(temp_dir, deploy_folder, opts) do
        {:ok, actions} ->
          {:ok, temp_dir, actions}

        {:error, _} = error ->
          File.rm_rf!(temp_dir)
          error
      end
    else
      {:error, _} = error ->
        error
    end
  end

  # SECTION: Backup

  defp create_backup(actions, deploy_folder) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601()
      |> String.replace(~r/[:\.]/, "-")

    backup_dir = Path.join([deploy_folder, ".backup", timestamp])
    modifiable_actions =
      actions
      |> Enum.reject(&match?({:identical, _}, &1))
      |> Enum.reject(&match?({:user_only, _}, &1))
      |> Enum.reject(&match?({:new, _}, &1))

    Enum.each(modifiable_actions, fn action ->
      user_paths = user_paths_for_action(action)

      Enum.each(user_paths, fn user_path ->
        src = Path.join(deploy_folder, user_path)

        if File.exists?(src) do
          dest = Path.join(backup_dir, user_path)
          File.mkdir_p!(Path.dirname(dest))
          File.cp!(src, dest)
        end
      end)
    end)

    backup_dir
  end

  defp user_paths_for_action({:update, _upstream, user}), do: [user]
  defp user_paths_for_action({:rename, _upstream, user}), do: [user]
  defp user_paths_for_action({:split, _upstream, users}), do: users
  defp user_paths_for_action({:merge_files, _upstreams, user}), do: [user]
  defp user_paths_for_action({:removed, _upstream}), do: []
  defp user_paths_for_action(_), do: []

  # SECTION: Interactive Mode

  defp run_interactive(actions, temp_dir, deploy_folder, backup_dir) do
    summary = categorize_actions(actions)
    print_category_summary(summary)

    if Enum.all?(Map.values(summary), &Enum.empty?/1) do
      Mix.shell().info([:green, "\nEverything is up to date!"])
    else
      applied = interactive_category_loop(summary, temp_dir, deploy_folder)
      print_final_summary(applied, backup_dir)
    end
  end

  defp categorize_actions(actions) do
    Enum.group_by(actions, &elem(&1, 0))
  end

  defp print_category_summary(summary) do
    Mix.shell().info([:cyan, "\n=== Upgrade Summary ===\n"])

    categories = [
      {:identical, "Identical (no changes)"},
      {:update, "Updates"},
      {:rename, "Renames"},
      {:split, "Splits"},
      {:merge_files, "Merges"},
      {:new, "New files"},
      {:removed, "Removed files"},
      {:user_only, "User-only files"}
    ]

    Enum.each(categories, fn {key, label} ->
      count = summary |> Map.get(key, []) |> length()

      if count > 0 do
        color = category_color(key)
        Mix.shell().info([color, "  #{count} #{label}"])
      end
    end)

    Mix.shell().info("")
  end

  defp category_color(:identical), do: :faint
  defp category_color(:update), do: :yellow
  defp category_color(:rename), do: :cyan
  defp category_color(:split), do: :cyan
  defp category_color(:merge_files), do: :cyan
  defp category_color(:new), do: :green
  defp category_color(:removed), do: :red
  defp category_color(:user_only), do: :faint

  defp interactive_category_loop(summary, temp_dir, deploy_folder) do
    selectable = [
      {:update, "Updates"},
      {:rename, "Renames"},
      {:split, "Splits"},
      {:merge_files, "Merges"},
      {:new, "New files"},
      {:removed, "Removed files"}
    ]

    available =
      selectable
      |> Enum.filter(fn {key, _} -> length(Map.get(summary, key, [])) > 0 end)

    if Enum.empty?(available) do
      Mix.shell().info([:green, "No actionable changes."])
      %{}
    else
      choices = Enum.map(available, fn {key, label} ->
        count = length(Map.get(summary, key, []))
        "#{label} (#{count})"
      end)

      selected = DeployEx.TUI.Select.run(
        choices ++ ["Done - apply all reviewed changes"],
        title: "Select a category to review"
      )

      case selected do
        [] ->
          Mix.shell().info([:yellow, "Cancelled."])
          %{}

        [choice] ->
          if String.starts_with?(choice, "Done") do
            %{}
          else
            index = Enum.find_index(choices, &(&1 === choice))
            {category_key, _label} = Enum.at(available, index)
            category_actions = Map.get(summary, category_key, [])

            applied = process_category(category_key, category_actions, temp_dir, deploy_folder)

            remaining_summary = Map.put(summary, category_key, [])
            more = interactive_category_loop(remaining_summary, temp_dir, deploy_folder)
            Map.merge(applied, more, fn _k, v1, v2 -> v1 + v2 end)
          end
      end
    end
  end

  defp process_category(:new, actions, temp_dir, deploy_folder) do
    count =
      Enum.count(actions, fn {:new, upstream_path} ->
        answer = Mix.shell().yes?("Add new file #{upstream_path}?")

        if answer do
          src = Path.join(temp_dir, upstream_path)
          dest = Path.join(deploy_folder, upstream_path)
          File.mkdir_p!(Path.dirname(dest))
          File.cp!(src, dest)
          Mix.shell().info([:green, "  + ", :reset, upstream_path])
        end

        answer
      end)

    %{new: count}
  end

  defp process_category(:removed, actions, _temp_dir, deploy_folder) do
    count =
      Enum.count(actions, fn {:removed, upstream_path} ->
        dest = Path.join(deploy_folder, upstream_path)
        answer = Mix.shell().yes?("Remove #{upstream_path}?")

        if answer and File.exists?(dest) do
          File.rm!(dest)
          Mix.shell().info([:red, "  - ", :reset, upstream_path])
        end

        answer
      end)

    %{removed: count}
  end

  defp process_category(:update, actions, temp_dir, deploy_folder) do
    count =
      Enum.count(actions, fn {:update, upstream_path, user_path} ->
        upstream_content = File.read!(Path.join(temp_dir, upstream_path))
        user_content = File.read!(Path.join(deploy_folder, user_path))

        case DeployEx.TUI.DiffViewer.run(user_content, upstream_content,
               title: "Update: #{user_path}",
               old_label: "yours",
               new_label: "upstream") do
          {:ok, merged} ->
            dest = Path.join(deploy_folder, user_path)
            File.write!(dest, merged)
            Mix.shell().info([:green, "  ~ ", :reset, user_path])
            true

          :cancelled ->
            Mix.shell().info([:yellow, "  skipped ", :reset, user_path])
            false
        end
      end)

    %{update: count}
  end

  defp process_category(:rename, actions, temp_dir, deploy_folder) do
    count =
      Enum.count(actions, fn {:rename, upstream_path, user_path} ->
        upstream_content = File.read!(Path.join(temp_dir, upstream_path))
        user_content = File.read!(Path.join(deploy_folder, user_path))

        Mix.shell().info([:cyan, "  Rename detected: ", :reset, user_path, :cyan, " <- ", :reset, upstream_path])

        case DeployEx.TUI.DiffViewer.run(user_content, upstream_content,
               title: "Rename: #{user_path}",
               old_label: "yours (#{user_path})",
               new_label: "upstream (#{upstream_path})") do
          {:ok, merged} ->
            dest = Path.join(deploy_folder, user_path)
            File.write!(dest, merged)
            Mix.shell().info([:green, "  ~ ", :reset, user_path])
            true

          :cancelled ->
            Mix.shell().info([:yellow, "  skipped ", :reset, user_path])
            false
        end
      end)

    %{rename: count}
  end

  defp process_category(:split, actions, temp_dir, deploy_folder) do
    count =
      Enum.count(actions, fn {:split, upstream_path, user_paths} ->
        upstream_content = File.read!(Path.join(temp_dir, upstream_path))
        Mix.shell().info([:cyan, "  Split: ", :reset, upstream_path, :cyan, " -> ", :reset, Enum.join(user_paths, ", ")])

        Enum.each(user_paths, fn user_path ->
          user_content = File.read!(Path.join(deploy_folder, user_path))

          case DeployEx.TUI.DiffViewer.run(user_content, upstream_content,
                 title: "Split: #{user_path} (from #{upstream_path})",
                 old_label: "yours (#{user_path})",
                 new_label: "upstream (#{upstream_path})") do
            {:ok, merged} ->
              dest = Path.join(deploy_folder, user_path)
              File.write!(dest, merged)
              Mix.shell().info([:green, "    ~ ", :reset, user_path])

            :cancelled ->
              Mix.shell().info([:yellow, "    skipped ", :reset, user_path])
          end
        end)

        true
      end)

    %{split: count}
  end

  defp process_category(:merge_files, actions, temp_dir, deploy_folder) do
    count =
      Enum.count(actions, fn {:merge_files, upstream_paths, user_path} ->
        concatenated_upstream =
          upstream_paths
          |> Enum.map(&File.read!(Path.join(temp_dir, &1)))
          |> Enum.join("\n")

        user_content = File.read!(Path.join(deploy_folder, user_path))
        Mix.shell().info([:cyan, "  Merge: ", :reset, Enum.join(upstream_paths, " + "), :cyan, " -> ", :reset, user_path])

        case DeployEx.TUI.DiffViewer.run(user_content, concatenated_upstream,
               title: "Merge: #{user_path}",
               old_label: "yours",
               new_label: "upstream (concatenated)") do
          {:ok, merged} ->
            dest = Path.join(deploy_folder, user_path)
            File.write!(dest, merged)
            Mix.shell().info([:green, "  ~ ", :reset, user_path])
            true

          :cancelled ->
            Mix.shell().info([:yellow, "  skipped ", :reset, user_path])
            false
        end
      end)

    %{merge_files: count}
  end

  # SECTION: AI-Assisted Mode

  defp run_ai_assisted(actions, temp_dir, deploy_folder, backup_dir) do
    non_trivial =
      actions
      |> Enum.reject(&match?({:identical, _}, &1))
      |> Enum.reject(&match?({:user_only, _}, &1))

    if Enum.empty?(non_trivial) do
      Mix.shell().info([:green, "\nEverything is up to date!"])
    else
      total = length(non_trivial)

      reviews =
        DeployEx.TUI.Progress.run_stream("AI Review", fn tui_pid ->
          non_trivial
          |> Enum.with_index(1)
          |> Enum.map(fn {action, index} ->
            label = action_label(action)
            DeployEx.TUI.Progress.update_progress(tui_pid, index / total, "Reviewing: #{label}")
            review = review_action_with_llm(action, temp_dir, deploy_folder)
            {action, review}
          end)
        end)

      present_ai_review(reviews, temp_dir, deploy_folder, backup_dir)
    end
  end

  defp review_action_with_llm(action, temp_dir, deploy_folder) do
    case DeployEx.LLMMerge.review_action(action, temp_dir, deploy_folder) do
      {:ok, review} -> review
      {:error, _} -> %{decision: :apply, rationale: "LLM review failed, defaulting to apply.", path: action_label(action)}
    end
  end

  defp present_ai_review(reviews, temp_dir, deploy_folder, backup_dir) do
    Mix.shell().info([:cyan, "\n=== AI Review Results ===\n"])

    choices =
      Enum.map(reviews, fn {action, review} ->
        decision_symbol = case review.decision do
          :apply -> "[+]"
          :skip -> "[-]"
        end

        "#{decision_symbol} #{action_label(action)} -- #{review.rationale}"
      end)

    selected = DeployEx.TUI.Select.run(
      choices ++ ["Apply all recommended", "Cancel"],
      title: "Confirm AI recommendations (select to toggle)",
      allow_all: true
    )

    case selected do
      [] ->
        Mix.shell().info([:yellow, "Cancelled."])

      [choice] when is_binary(choice) ->
        cond do
          String.starts_with?(choice, "Apply all") ->
            apply_ai_recommendations(reviews, temp_dir, deploy_folder)
            print_final_summary(%{ai_applied: length(reviews)}, backup_dir)

          String.starts_with?(choice, "Cancel") ->
            Mix.shell().info([:yellow, "Cancelled."])

          true ->
            index = Enum.find_index(choices, &(&1 === choice))
            {action, _review} = Enum.at(reviews, index)
            apply_single_action(action, temp_dir, deploy_folder)
            print_final_summary(%{ai_applied: 1}, backup_dir)
        end

      all when is_list(all) ->
        apply_ai_recommendations(reviews, temp_dir, deploy_folder)
        print_final_summary(%{ai_applied: length(reviews)}, backup_dir)
    end
  end

  defp apply_ai_recommendations(reviews, temp_dir, deploy_folder) do
    Enum.each(reviews, fn {action, review} ->
      if review.decision === :apply do
        apply_single_action(action, temp_dir, deploy_folder)
      end
    end)
  end

  # SECTION: Autonomous Mode

  defp run_autonomous(actions, temp_dir, deploy_folder, backup_dir) do
    non_trivial =
      actions
      |> Enum.reject(&match?({:identical, _}, &1))
      |> Enum.reject(&match?({:user_only, _}, &1))

    if Enum.empty?(non_trivial) do
      Mix.shell().info([:green, "\nEverything is up to date!"])
    else
      total = length(non_trivial)

      result =
        DeployEx.TUI.Progress.run_stream("Autonomous Upgrade", fn tui_pid ->
          non_trivial
          |> Enum.with_index(1)
          |> Enum.each(fn {action, index} ->
            label = action_label(action)
            DeployEx.TUI.Progress.update_progress(tui_pid, index / total, "Applying: #{label}")
            apply_single_action_with_llm(action, temp_dir, deploy_folder)
          end)

          :ok
        end)

      case result do
        :ok -> print_autonomous_summary(non_trivial, backup_dir)
        {:error, :cancelled} -> Mix.shell().info([:yellow, "\nCancelled."])
        {:error, reason} -> Mix.shell().error("Upgrade failed: #{inspect(reason)}")
      end
    end
  end

  defp apply_single_action_with_llm(action, temp_dir, deploy_folder) do
    case action do
      {:new, _upstream_path} ->
        apply_single_action(action, temp_dir, deploy_folder)

      {:removed, _} ->
        :ok

      {:update, upstream_path, user_path} ->
        upstream_content = File.read!(Path.join(temp_dir, upstream_path))
        user_content = File.read!(Path.join(deploy_folder, user_path))

        case DeployEx.LLMMerge.merge_file(user_content, upstream_content) do
          {:ok, merged} ->
            dest = Path.join(deploy_folder, user_path)
            File.write!(dest, merged)
            Mix.shell().info([:green, "  ~ ", :reset, user_path, " (LLM merged)"])

          {:error, _} ->
            apply_single_action(action, temp_dir, deploy_folder)
        end

      {:rename, upstream_path, user_path} ->
        upstream_content = File.read!(Path.join(temp_dir, upstream_path))
        user_content = File.read!(Path.join(deploy_folder, user_path))

        case DeployEx.LLMMerge.merge_file(user_content, upstream_content) do
          {:ok, merged} ->
            dest = Path.join(deploy_folder, user_path)
            File.write!(dest, merged)
            Mix.shell().info([:green, "  ~ ", :reset, user_path, " (LLM merged rename)"])

          {:error, _} ->
            apply_single_action(action, temp_dir, deploy_folder)
        end

      {:split, upstream_path, user_paths} ->
        upstream_content = File.read!(Path.join(temp_dir, upstream_path))

        Enum.each(user_paths, fn user_path ->
          user_content = File.read!(Path.join(deploy_folder, user_path))

          case DeployEx.LLMMerge.merge_file(user_content, upstream_content) do
            {:ok, merged} ->
              dest = Path.join(deploy_folder, user_path)
              File.write!(dest, merged)

            {:error, _} ->
              :ok
          end
        end)

      {:merge_files, upstream_paths, user_path} ->
        concatenated =
          upstream_paths
          |> Enum.map(&File.read!(Path.join(temp_dir, &1)))
          |> Enum.join("\n")

        user_content = File.read!(Path.join(deploy_folder, user_path))

        case DeployEx.LLMMerge.merge_file(user_content, concatenated) do
          {:ok, merged} ->
            dest = Path.join(deploy_folder, user_path)
            File.write!(dest, merged)

          {:error, _} ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # SECTION: Action Application

  defp apply_single_action({:new, upstream_path}, temp_dir, deploy_folder) do
    src = Path.join(temp_dir, upstream_path)
    dest = Path.join(deploy_folder, upstream_path)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(src, dest)
    Mix.shell().info([:green, "  + ", :reset, upstream_path])
  end

  defp apply_single_action({:update, upstream_path, user_path}, temp_dir, deploy_folder) do
    src = Path.join(temp_dir, upstream_path)
    dest = Path.join(deploy_folder, user_path)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(src, dest)
    Mix.shell().info([:green, "  ~ ", :reset, user_path])
  end

  defp apply_single_action({:rename, upstream_path, user_path}, temp_dir, deploy_folder) do
    src = Path.join(temp_dir, upstream_path)
    dest = Path.join(deploy_folder, user_path)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(src, dest)
    Mix.shell().info([:green, "  ~ ", :reset, user_path, " (renamed from #{upstream_path})"])
  end

  defp apply_single_action({:removed, upstream_path}, _temp_dir, deploy_folder) do
    dest = Path.join(deploy_folder, upstream_path)

    if File.exists?(dest) do
      File.rm!(dest)
      Mix.shell().info([:red, "  - ", :reset, upstream_path])
    end
  end

  defp apply_single_action(_, _temp_dir, _deploy_folder), do: :ok

  # SECTION: Output

  defp action_label({:identical, path}), do: path
  defp action_label({:update, _up, user}), do: user
  defp action_label({:rename, up, user}), do: "#{user} <- #{up}"
  defp action_label({:split, up, users}), do: "#{up} -> #{Enum.join(users, ", ")}"
  defp action_label({:merge_files, ups, user}), do: "#{Enum.join(ups, " + ")} -> #{user}"
  defp action_label({:new, path}), do: "#{path} (new)"
  defp action_label({:removed, path}), do: "#{path} (removed)"
  defp action_label({:user_only, path}), do: "#{path} (user-only)"

  defp print_final_summary(counts, backup_dir) do
    Mix.shell().info([:green, "\n=== Upgrade Complete ==="])

    Enum.each(counts, fn {key, count} ->
      if count > 0 do
        Mix.shell().info("  #{count} #{key} action(s) applied")
      end
    end)

    if File.exists?(backup_dir) do
      Mix.shell().info([:yellow, "\nBackups saved to: #{backup_dir}"])
    end
  end

  defp print_autonomous_summary(actions, backup_dir) do
    Mix.shell().info([:green, "\n=== Autonomous Upgrade Complete ==="])
    Mix.shell().info("  #{length(actions)} action(s) processed")

    if File.exists?(backup_dir) do
      Mix.shell().info([:yellow, "\nBackups saved to: #{backup_dir}"])
      Mix.shell().info("  To undo a file: cp #{backup_dir}/<path> ./deploys/<path>")
    end
  end

  # SECTION: Manifest

  defp update_manifest(deploy_folder) do
    manifest =
      deploy_folder
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.reject(&String.starts_with?(Path.relative_to(&1, deploy_folder), "."))
      |> Enum.reduce(
        [deploy_ex_version: to_string(Application.spec(:deploy_ex, :vsn)), files: []],
        fn file_path, acc ->
          relative = Path.relative_to(file_path, deploy_folder)
          hash = file_path |> File.read!() |> DeployEx.PrivManifest.hash_content()
          DeployEx.PrivManifest.put_file(acc, relative, hash)
        end
      )

    DeployEx.PrivManifest.write(deploy_folder, manifest)
    Mix.shell().info([:green, "* manifest updated"])
  end

  # SECTION: Arg Parsing

  defp parse_args(args) do
    {opts, _} =
      OptionParser.parse!(args,
        switches: [llm_merge: :boolean, ai_review: :boolean]
      )

    opts
  end
end
