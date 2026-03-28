defmodule DeployEx.TUI.DiffViewer do
  @moduledoc """
  Interactive TUI component for reviewing unified diffs with hunk-level
  accept/reject. Supports scrollable diff display, hunk navigation,
  and a console fallback for non-TUI environments.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

  # SECTION: Public API

  @spec run(String.t(), String.t(), keyword()) :: {:ok, String.t()} | :cancelled
  def run(old_content, new_content, opts \\ []) do
    case DeployEx.Diff.compute(old_content, new_content) do
      {:ok, []} ->
        {:ok, old_content}

      {:ok, hunks} ->
        if DeployEx.TUI.enabled?() do
          run_tui(old_content, hunks, opts)
        else
          run_console(old_content, hunks, opts)
        end

      {:error, _reason} ->
        {:ok, old_content}
    end
  end

  # SECTION: Console Fallback

  defp run_console(old_content, hunks, opts) do
    title = Keyword.get(opts, :title, "Diff Review")
    Mix.shell().info("\n--- #{title} ---\n")

    resolved_hunks = Enum.reduce_while(hunks, [], fn hunk, acc ->
      print_hunk_console(hunk)

      case prompt_hunk_action() do
        :accept -> {:cont, [%{hunk | status: :accepted} | acc]}
        :reject -> {:cont, [%{hunk | status: :rejected} | acc]}
        :all -> {:halt, mark_remaining_hunks(:accepted, [hunk | remaining_from(hunks, acc)], acc)}
        :quit -> {:halt, :cancelled}
      end
    end)

    case resolved_hunks do
      :cancelled ->
        :cancelled

      resolved when is_list(resolved) ->
        merged = resolved
          |> Enum.reverse()
          |> then(&DeployEx.Diff.apply_hunks(old_content, &1))

        {:ok, merged}
    end
  end

  defp print_hunk_console(hunk) do
    Mix.shell().info(IO.ANSI.cyan() <> hunk.header <> IO.ANSI.reset())

    Enum.each(hunk.lines, fn line ->
      case line.type do
        :added -> Mix.shell().info(IO.ANSI.green() <> "+ #{line.text}" <> IO.ANSI.reset())
        :removed -> Mix.shell().info(IO.ANSI.red() <> "- #{line.text}" <> IO.ANSI.reset())
        :context -> Mix.shell().info("  #{line.text}")
      end
    end)
  end

  defp prompt_hunk_action do
    response = "Accept this hunk? [y/n/a(ll)/q(uit)] "
      |> Mix.shell().prompt()
      |> String.trim()
      |> String.downcase()

    case response do
      "y" -> :accept
      "n" -> :reject
      "a" -> :all
      "q" -> :quit
      _ -> prompt_hunk_action()
    end
  end

  defp remaining_from(all_hunks, already_processed) do
    Enum.drop(all_hunks, length(already_processed) + 1)
  end

  defp mark_remaining_hunks(status, remaining, acc) do
    remaining
    |> Enum.map(&%{&1 | status: status})
    |> Enum.reverse()
    |> Kernel.++(acc)
  end

  # SECTION: TUI Mode

  defp run_tui(old_content, hunks, opts) do
    title = Keyword.get(opts, :title, "Diff Review")

    {diff_text, hunk_line_offsets} = build_diff_text(hunks)

    ExRatatui.run(fn terminal ->
      {width, height} = ExRatatui.terminal_size()

      initial_state = %{
        hunks: hunks,
        current_hunk: 0,
        scroll: 0,
        title: title,
        diff_text: diff_text,
        hunk_line_offsets: hunk_line_offsets,
        old_content: old_content,
        result: nil
      }

      tui_loop(terminal, initial_state, width, height)
    end)
  end

  defp tui_loop(terminal, state, width, height) do
    draw_tui(terminal, state, width, height)

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Key{code: "n", kind: "press"} ->
        max_index = max(length(state.hunks) - 1, 0)
        new_index = min(state.current_hunk + 1, max_index)
        scroll = Enum.at(state.hunk_line_offsets, new_index, 0)
        tui_loop(terminal, %{state | current_hunk: new_index, scroll: scroll}, width, height)

      %ExRatatui.Event.Key{code: "p", kind: "press"} ->
        new_index = max(state.current_hunk - 1, 0)
        scroll = Enum.at(state.hunk_line_offsets, new_index, 0)
        tui_loop(terminal, %{state | current_hunk: new_index, scroll: scroll}, width, height)

      %ExRatatui.Event.Key{code: "a", kind: "press"} ->
        state
        |> update_hunk_status(state.current_hunk, :accepted)
        |> rebuild_diff_text()
        |> then(&tui_loop(terminal, &1, width, height))

      %ExRatatui.Event.Key{code: "r", kind: "press"} ->
        state
        |> update_hunk_status(state.current_hunk, :rejected)
        |> rebuild_diff_text()
        |> then(&tui_loop(terminal, &1, width, height))

      %ExRatatui.Event.Key{code: "A", kind: "press"} ->
        state
        |> update_all_hunks(:accepted)
        |> rebuild_diff_text()
        |> then(&tui_loop(terminal, &1, width, height))

      %ExRatatui.Event.Key{code: "R", kind: "press"} ->
        state
        |> update_all_hunks(:rejected)
        |> rebuild_diff_text()
        |> then(&tui_loop(terminal, &1, width, height))

      %ExRatatui.Event.Key{code: "up", kind: "press"} ->
        new_scroll = max(state.scroll - 1, 0)
        tui_loop(terminal, %{state | scroll: new_scroll}, width, height)

      %ExRatatui.Event.Key{code: "down", kind: "press"} ->
        new_scroll = state.scroll + 1
        tui_loop(terminal, %{state | scroll: new_scroll}, width, height)

      %ExRatatui.Event.Key{code: "enter", kind: "press"} ->
        merged = state.hunks
          |> then(&DeployEx.Diff.apply_hunks(state.old_content, &1))

        {:ok, merged}

      %ExRatatui.Event.Key{code: "q", kind: "press"} ->
        :cancelled

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} ->
        :cancelled

      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        tui_loop(terminal, state, new_width, new_height)

      _ ->
        tui_loop(terminal, state, width, height)
    end
  end

  # SECTION: TUI Drawing

  defp draw_tui(terminal, state, width, height) do
    area = %Rect{x: 0, y: 0, width: width, height: height}
    [diff_area, status_area] = Layout.split(area, :vertical, [{:min, 5}, {:length, 3}])

    diff_widget = %Widgets.Paragraph{
      text: state.diff_text,
      wrap: false,
      scroll: {state.scroll, 0},
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: " #{state.title} ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    status_text = build_status_bar(state)

    status_widget = %Widgets.Paragraph{
      text: status_text,
      wrap: false,
      scroll: {0, 0},
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: " Keys: n/p=nav  a/r=accept/reject  A/R=all  Enter=done  q=cancel ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :yellow}
      }
    }

    ExRatatui.draw(terminal, [{diff_widget, diff_area}, {status_widget, status_area}])
  end

  # SECTION: Diff Text Building

  defp build_diff_text(hunks) do
    {lines, offsets, _line_count} =
      Enum.reduce(hunks, {[], [], 0}, fn hunk, {lines_acc, offsets_acc, line_count} ->
        status_prefix = status_label(hunk.status)
        header_line = "#{status_prefix} #{hunk.header}"

        hunk_lines = Enum.map(hunk.lines, fn line ->
          case line.type do
            :added -> "+ #{line.text}"
            :removed -> "- #{line.text}"
            :context -> "  #{line.text}"
          end
        end)

        all_lines = [header_line | hunk_lines] ++ [""]
        new_line_count = line_count + length(all_lines)

        {lines_acc ++ all_lines, offsets_acc ++ [line_count], new_line_count}
      end)

    text = Enum.join(lines, "\n")
    {text, offsets}
  end

  defp status_label(:accepted), do: "[ACCEPT]"
  defp status_label(:rejected), do: "[REJECT]"
  defp status_label(:pending), do: "[?????]"

  defp build_status_bar(state) do
    indicators = state.hunks
      |> Enum.with_index()
      |> Enum.map(fn {hunk, index} ->
        symbol = case hunk.status do
          :accepted -> "+"
          :rejected -> "-"
          :pending -> "?"
        end

        if index === state.current_hunk do
          ">[#{symbol}]<"
        else
          " [#{symbol}] "
        end
      end)
      |> Enum.join("")

    "Hunks: #{indicators}"
  end

  # SECTION: State Helpers

  defp update_hunk_status(state, index, status) do
    updated_hunks = List.update_at(state.hunks, index, &%{&1 | status: status})
    %{state | hunks: updated_hunks}
  end

  defp update_all_hunks(state, status) do
    updated_hunks = Enum.map(state.hunks, &%{&1 | status: status})
    %{state | hunks: updated_hunks}
  end

  defp rebuild_diff_text(state) do
    {diff_text, hunk_line_offsets} = build_diff_text(state.hunks)
    %{state | diff_text: diff_text, hunk_line_offsets: hunk_line_offsets}
  end
end
