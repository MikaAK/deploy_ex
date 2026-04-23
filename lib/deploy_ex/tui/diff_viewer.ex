defmodule DeployEx.TUI.DiffViewer do
  @moduledoc """
  Interactive TUI component for reviewing diffs with per-line accept/reject.
  Each changed line can be individually toggled. Context lines are always kept.
  Supports scrollable display and a console fallback.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

  # SECTION: Types

  @type line_entry :: %{
          type: :context | :added | :removed,
          text: String.t(),
          status: :keep | :accept | :reject,
          hunk_index: non_neg_integer()
        }

  # SECTION: Public API

  @spec run(String.t(), String.t(), keyword()) :: {:ok, String.t()} | :cancelled
  def run(old_content, new_content, opts \\ []) do
    case DeployEx.Diff.compute(old_content, new_content) do
      {:ok, []} ->
        {:ok, old_content}

      {:ok, hunks} ->
        lines = flatten_hunks_to_lines(hunks)

        if DeployEx.TUI.enabled?() do
          run_tui(old_content, lines, opts)
        else
          run_console(old_content, lines, opts)
        end

      {:error, _reason} ->
        {:ok, old_content}
    end
  end

  # SECTION: Flatten Hunks to Line Entries

  defp flatten_hunks_to_lines(hunks) do
    hunks
    |> Enum.with_index()
    |> Enum.flat_map(fn {hunk, hunk_idx} ->
      header = %{type: :header, text: hunk.header, status: :keep, hunk_index: hunk_idx}

      lines =
        Enum.map(hunk.lines, fn line ->
          status = if line.type === :context, do: :keep, else: :accept
          %{type: line.type, text: line.text, status: status, hunk_index: hunk_idx}
        end)

      [header | lines]
    end)
  end

  # SECTION: Console Fallback

  defp run_console(old_content, lines, opts) do
    title = Keyword.get(opts, :title, "Diff Review")
    Mix.shell().info("\n--- #{title} ---\n")

    resolved = Enum.reduce_while(lines, lines, fn _line, acc ->
      print_lines_console(acc)
      Mix.shell().info("")
      Mix.shell().info("[N] toggle line N  [a] accept all  [r] reject all  [Enter] done  [q] cancel")

      input =
        "Action: "
        |> Mix.shell().prompt()
        |> String.trim()
        |> String.downcase()

      cond do
        input === "" -> {:halt, {:done, acc}}
        input === "q" -> {:halt, :cancelled}
        input === "a" -> {:cont, set_all_changed(acc, :accept)}
        input === "r" -> {:cont, set_all_changed(acc, :reject)}

        true ->
          case Integer.parse(input) do
            {idx, _} when idx >= 0 and idx < length(acc) ->
              {:cont, toggle_line(acc, idx)}

            _ ->
              {:cont, acc}
          end
      end
    end)

    case resolved do
      :cancelled -> :cancelled
      {:done, final_lines} -> {:ok, apply_line_decisions(old_content, final_lines)}
      final_lines when is_list(final_lines) -> {:ok, apply_line_decisions(old_content, final_lines)}
    end
  end

  defp print_lines_console(lines) do
    lines
    |> Enum.with_index()
    |> Enum.each(fn {line, idx} ->
      prefix = line_prefix(line)
      status_mark = line_status_mark(line)

      case line.type do
        :header -> Mix.shell().info([:cyan, "    #{line.text}"])
        :added -> Mix.shell().info([:green, "#{idx}) #{status_mark} +#{line.text}"])
        :removed -> Mix.shell().info([:red, "#{idx}) #{status_mark} -#{line.text}"])
        :context -> Mix.shell().info("    #{prefix}#{line.text}")
      end
    end)
  end

  # SECTION: TUI Mode

  defp run_tui(old_content, lines, opts) do
    title = Keyword.get(opts, :title, "Diff Review")

    result = DeployEx.TUI.run(fn terminal ->
      {width, height} = ExRatatui.terminal_size()

      state = %{
        lines: lines,
        selected: 0,
        scroll: 0,
        title: title,
        old_content: old_content
      }

      tui_loop(terminal, state, width, height)
    end)

    case result do
      :cancelled -> :cancelled
      {:ok, final_lines} -> {:ok, apply_line_decisions(old_content, final_lines)}
    end
  end

  defp tui_loop(terminal, state, width, height) do
    draw_tui(terminal, state, width, height)

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Key{code: "up", kind: "press"} ->
        new_sel = max(state.selected - 1, 0)
        scroll = adjust_scroll(new_sel, state.scroll, height - 6)
        tui_loop(terminal, %{state | selected: new_sel, scroll: scroll}, width, height)

      %ExRatatui.Event.Key{code: "down", kind: "press"} ->
        max_idx = max(length(state.lines) - 1, 0)
        new_sel = min(state.selected + 1, max_idx)
        scroll = adjust_scroll(new_sel, state.scroll, height - 6)
        tui_loop(terminal, %{state | selected: new_sel, scroll: scroll}, width, height)

      %ExRatatui.Event.Key{code: " ", kind: "press"} ->
        lines = toggle_line(state.lines, state.selected)
        tui_loop(terminal, %{state | lines: lines}, width, height)

      %ExRatatui.Event.Key{code: "a", kind: "press"} ->
        lines = set_all_changed(state.lines, :accept)
        tui_loop(terminal, %{state | lines: lines}, width, height)

      %ExRatatui.Event.Key{code: "r", kind: "press"} ->
        lines = set_all_changed(state.lines, :reject)
        tui_loop(terminal, %{state | lines: lines}, width, height)

      %ExRatatui.Event.Key{code: "enter", kind: "press"} ->
        {:ok, state.lines}

      %ExRatatui.Event.Key{code: "q", kind: "press"} ->
        :cancelled

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} ->
        :cancelled

      %ExRatatui.Event.Resize{width: new_w, height: new_h} ->
        tui_loop(terminal, state, new_w, new_h)

      _ ->
        tui_loop(terminal, state, width, height)
    end
  end

  # SECTION: TUI Drawing

  defp draw_tui(terminal, state, width, height) do
    area = %Rect{x: 0, y: 0, width: width, height: height}
    [diff_area, help_area] = Layout.split(area, :vertical, [{:min, 5}, {:length, 3}])

    display_lines = build_display_lines(state.lines)

    accepted = Enum.count(state.lines, &(&1.status === :accept))
    rejected = Enum.count(state.lines, &(&1.status === :reject))
    total_changed = Enum.count(state.lines, &(&1.type in [:added, :removed]))

    list_widget = %Widgets.List{
      items: display_lines,
      selected: state.selected,
      highlight_style: %Style{fg: :white, modifiers: [:bold]},
      highlight_symbol: "▸ ",
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: " #{state.title} (#{accepted}/#{total_changed} accepted, #{rejected} rejected) ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    help_widget = %Widgets.Paragraph{
      text: "[Space] toggle line  [a] accept all  [r] reject all  [Enter] done  [q] cancel",
      style: %Style{fg: :yellow},
      block: %Widgets.Block{
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :yellow}
      }
    }

    ExRatatui.draw(terminal, [{list_widget, diff_area}, {help_widget, help_area}])
  end

  defp build_display_lines(lines) do
    Enum.map(lines, fn line ->
      status_mark = line_status_mark(line)
      prefix = line_prefix(line)

      case line.type do
        :header -> "  #{line.text}"
        :added -> "#{status_mark} +#{line.text}"
        :removed -> "#{status_mark} -#{line.text}"
        :context -> "   #{prefix}#{line.text}"
      end
    end)
  end

  # SECTION: Line Helpers

  defp line_prefix(%{type: :context}), do: " "
  defp line_prefix(_), do: ""

  defp line_status_mark(%{type: type}) when type in [:context, :header], do: "  "
  defp line_status_mark(%{status: :accept}), do: "✓"
  defp line_status_mark(%{status: :reject}), do: "✗"
  defp line_status_mark(_), do: "?"

  defp toggle_line(lines, index) do
    line = Enum.at(lines, index)

    if line.type in [:added, :removed] do
      new_status = if line.status === :accept, do: :reject, else: :accept
      List.replace_at(lines, index, %{line | status: new_status})
    else
      lines
    end
  end

  defp set_all_changed(lines, status) do
    Enum.map(lines, fn line ->
      if line.type in [:added, :removed] do
        %{line | status: status}
      else
        line
      end
    end)
  end

  defp adjust_scroll(selected, current_scroll, visible_height) do
    cond do
      selected < current_scroll -> selected
      selected >= current_scroll + visible_height -> selected - visible_height + 1
      true -> current_scroll
    end
  end

  # SECTION: Apply Line Decisions

  defp apply_line_decisions(old_content, lines) do
    # Reconstruct hunks from line decisions, then apply
    hunks = reconstruct_hunks(lines)
    DeployEx.Diff.apply_hunks(old_content, hunks)
  end

  defp reconstruct_hunks(lines) do
    lines
    |> Enum.reject(&(&1.type === :header))
    |> Enum.group_by(& &1.hunk_index)
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, hunk_lines} ->
      # Filter out rejected lines from the hunk
      filtered_lines =
        Enum.flat_map(hunk_lines, fn line ->
          case {line.type, line.status} do
            {:context, _} -> [%{type: :context, text: line.text}]
            {:added, :accept} -> [%{type: :added, text: line.text}]
            {:added, :reject} -> []
            {:removed, :accept} -> [%{type: :removed, text: line.text}]
            {:removed, :reject} -> [%{type: :context, text: line.text}]
          end
        end)

      %{header: "@@ synthesized @@", lines: filtered_lines, status: :accepted}
    end)
  end
end
