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
  def run([choice], _opts), do: [choice]

  def run(choices, opts) when is_list(choices) do
    if DeployEx.TUI.enabled?() do
      run_tui(choices, opts)
    else
      run_console(choices, opts)
    end
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

  defp run_tui(choices, opts) do
    allow_all = Keyword.get(opts, :allow_all, false)
    title = Keyword.get(opts, :title, "Select an option")

    ExRatatui.run(fn terminal ->
      {width, height} = ExRatatui.terminal_size()

      initial_state = %{
        choices: choices,
        selected: 0,
        allow_all: allow_all,
        title: title,
        result: nil
      }

      loop(terminal, initial_state, width, height)
    end)
  end

  defp loop(terminal, state, width, height) do
    draw(terminal, state, width, height)

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Key{code: "up", kind: "press"} ->
        new_selected = max(state.selected - 1, 0)
        loop(terminal, %{state | selected: new_selected}, width, height)

      %ExRatatui.Event.Key{code: "down", kind: "press"} ->
        max_index = length(state.choices) - 1
        new_selected = min(state.selected + 1, max_index)
        loop(terminal, %{state | selected: new_selected}, width, height)

      %ExRatatui.Event.Key{code: "enter", kind: "press"} ->
        [Enum.at(state.choices, state.selected)]

      %ExRatatui.Event.Key{code: "a", kind: "press"} when state.allow_all ->
        state.choices

      %ExRatatui.Event.Key{code: "q", kind: "press"} ->
        []

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} ->
        []

      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        loop(terminal, state, new_width, new_height)

      _ ->
        loop(terminal, state, width, height)
    end
  end

  defp draw(terminal, state, width, height) do
    title_text = if state.allow_all do
      " #{state.title} (↑↓ navigate, Enter select, a=all, q=quit) "
    else
      " #{state.title} (↑↓ navigate, Enter select, q=quit) "
    end

    list_widget = %Widgets.List{
      items: state.choices,
      selected: state.selected,
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      highlight_symbol: " ▸ ",
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: title_text,
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
