defmodule DeployEx.TUI.Select do
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

  @type option :: %{
    allow_all: boolean()
  }

  @spec run(list(String.t()), keyword()) :: list(String.t())
  def run(choices, opts \\ [])

  def run([], opts) do
    if always_prompt?(opts), do: run_tui([], opts), else: []
  end

  def run([choice] = choices, opts) do
    if always_prompt?(opts), do: run_tui(choices, opts), else: [choice]
  end

  def run(choices, opts) when is_list(choices) do
    if DeployEx.TUI.enabled?() do
      run_tui(choices, opts)
    else
      run_console(choices, opts)
    end
  end

  defp always_prompt?(opts) do
    Keyword.get(opts, :always_prompt, false) && DeployEx.TUI.enabled?()
  end

  defp run_console(choices, opts) do
    select_all? = Keyword.get(opts, :allow_all, false)

    Enum.each(Enum.with_index(choices), fn {value, index} ->
      Mix.shell().info("#{index}) #{value}")
    end)

    prompt = "Make a selection between 0 and #{length(choices) - 1}"
    prompt = if select_all?, do: "#{prompt}, or type a to select all:", else: prompt

    value = prompt |> Mix.shell().prompt() |> String.trim()

    cond do
      value === "" -> run_console(choices, opts)
      value === "a" and select_all? -> choices

      String.match?(value, ~r/^\d+$/) and
        String.to_integer(value) in Range.new(0, length(choices) - 1) ->
        value |> String.to_integer() |> then(&[Enum.at(choices, &1)])

      true -> run_console(choices, opts)
    end
  end

  @spec run_in_terminal(ExRatatui.terminal_ref(), list(String.t()), keyword()) :: list(String.t())
  def run_in_terminal(terminal, choices, opts \\ [])

  def run_in_terminal(terminal, [], opts) do
    if always_prompt_in_terminal?(opts), do: run_loop_in_terminal(terminal, [], opts), else: []
  end

  def run_in_terminal(terminal, [choice] = choices, opts) do
    if always_prompt_in_terminal?(opts),
      do: run_loop_in_terminal(terminal, choices, opts),
      else: [choice]
  end

  def run_in_terminal(terminal, choices, opts) when is_list(choices) do
    run_loop_in_terminal(terminal, choices, opts)
  end

  defp always_prompt_in_terminal?(opts), do: Keyword.get(opts, :always_prompt, false)

  defp run_loop_in_terminal(terminal, choices, opts) do
    loop(terminal, build_initial_state(choices, opts), ExRatatui.terminal_size())
  end

  defp run_tui(choices, opts) do
    DeployEx.TUI.run(fn terminal ->
      loop(terminal, build_initial_state(choices, opts), ExRatatui.terminal_size())
    end)
  end

  defp build_initial_state(choices, opts) do
    %{
      choices: choices,
      selected: 0,
      allow_all: Keyword.get(opts, :allow_all, false),
      multi_select: Keyword.get(opts, :multi_select, false),
      picked: MapSet.new(),
      title: Keyword.get(opts, :title, "Select an option"),
      result: nil
    }
  end

  defp loop(terminal, state, {width, height}) do
    draw(terminal, state, width, height)

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Key{code: "up", kind: "press"} ->
        loop(terminal, %{state | selected: max(state.selected - 1, 0)}, {width, height})

      %ExRatatui.Event.Key{code: "down", kind: "press"} ->
        loop(terminal, %{state | selected: min(state.selected + 1, max_index(state))}, {width, height})

      %ExRatatui.Event.Key{code: "enter", kind: "press"} ->
        handle_enter(terminal, state, {width, height})

      %ExRatatui.Event.Key{code: "a", kind: "press"} when state.allow_all ->
        state.choices

      %ExRatatui.Event.Key{code: "q", kind: "press"} ->
        []

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} ->
        []

      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        loop(terminal, state, {new_width, new_height})

      _ ->
        loop(terminal, state, {width, height})
    end
  end

  defp max_index(%{multi_select: true, choices: choices}), do: length(choices)
  defp max_index(%{choices: choices}), do: max(length(choices) - 1, 0)

  defp handle_enter(terminal, %{multi_select: true} = state, dimensions) do
    if on_ok_row?(state) do
      confirm_multi_select(state)
    else
      loop(terminal, %{state | picked: toggle_pick(state.picked, state.selected)}, dimensions)
    end
  end

  defp handle_enter(_terminal, state, _dimensions) do
    [Enum.at(state.choices, state.selected)]
  end

  defp on_ok_row?(%{selected: selected, choices: choices}), do: selected === length(choices)

  defp toggle_pick(picked, index) do
    if MapSet.member?(picked, index),
      do: MapSet.delete(picked, index),
      else: MapSet.put(picked, index)
  end

  defp confirm_multi_select(%{picked: picked, choices: choices}) do
    picked |> Enum.sort() |> Enum.map(&Enum.at(choices, &1))
  end

  defp render_items(%{multi_select: true, picked: picked, choices: choices}) do
    toggles =
      choices
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} ->
        marker = if MapSet.member?(picked, index), do: "[✓]", else: "[ ]"
        "#{marker} #{choice}"
      end)

    toggles ++ [ok_row_label(picked)]
  end

  defp render_items(%{choices: choices}), do: choices

  defp ok_row_label(picked) do
    count = MapSet.size(picked)
    "── ✔ OK — confirm selection (#{count} picked) ──"
  end

  defp title_text(state) do
    hints =
      [
        "↑↓ navigate",
        if(state.multi_select, do: "Enter toggle/OK", else: "Enter select"),
        if(state.allow_all, do: "a=all", else: nil),
        "q=quit"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    " #{state.title} (#{hints}) "
  end

  defp draw(terminal, state, width, height) do
    list_widget = %Widgets.List{
      items: render_items(state),
      selected: state.selected,
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      highlight_symbol: " ▸ ",
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: title_text(state),
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    area = %Rect{x: 0, y: 0, width: width, height: height}

    [_padding_top, content_area, _padding_bottom] = Layout.split(area, :vertical, [
      {:length, 1},
      {:min, 3},
      {:length, 1}
    ])

    [_padding_left, inner_area, _padding_right] = Layout.split(content_area, :horizontal, [
      {:length, 2},
      {:min, 10},
      {:length, 2}
    ])

    ExRatatui.draw(terminal, [{list_widget, inner_area}])
  end
end
