defmodule DeployEx.TUI.Wizard do
  alias DeployEx.TUI.Wizard.CommandRegistry
  alias DeployEx.TUI.Wizard.Form
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    if DeployEx.TUI.enabled?() do
      run_tui(opts)
    else
      run_console(opts)
    end
  end

  defp run_console(_opts) do
    categories = CommandRegistry.categories()

    Enum.each(Enum.with_index(categories), fn {cat, idx} ->
      Mix.shell().info("#{idx}) #{cat}")
    end)

    raw = "Select a category: " |> Mix.shell().prompt() |> String.trim()
    category = parse_console_selection(raw, categories)

    if is_nil(category) do
      Mix.shell().info([:yellow, "No category selected"])
    else
      commands = CommandRegistry.commands_for_category(category)

      Enum.each(Enum.with_index(commands), fn {cmd, idx} ->
        shortdoc = CommandRegistry.shortdoc_for(cmd)
        Mix.shell().info("#{idx}) #{cmd.task} — #{shortdoc}")
      end)

      raw2 = "Select a command: " |> Mix.shell().prompt() |> String.trim()
      command = parse_console_selection(raw2, commands)

      if is_nil(command) do
        Mix.shell().info([:yellow, "No command selected"])
      else
        run_selected_command(command)
      end
    end
  end

  defp parse_console_selection(raw, items) do
    if String.match?(raw, ~r/^\d+$/) do
      idx = String.to_integer(raw)
      Enum.at(items, idx)
    else
      nil
    end
  end

  defp run_tui(_opts) do
    command = pick_command_tui()

    case command do
      nil ->
        :ok

      cmd ->
        case Form.run(cmd) do
          :cancelled -> :ok
          {:ok, values} -> execute_with_values(cmd, values)
        end
    end
  end

  defp pick_command_tui do
    initial_state = %{
      screen: :category_select,
      category_selected: 0,
      command_selected: 0,
      search_query: "",
      search_selected: 0,
      width: 80,
      height: 24
    }

    ExRatatui.run(fn terminal ->
      {width, height} = ExRatatui.terminal_size()
      wizard_loop(terminal, %{initial_state | width: width, height: height})
    end)
  end

  defp wizard_loop(terminal, state) do
    draw(terminal, state)

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Resize{width: w, height: h} ->
        wizard_loop(terminal, %{state | width: w, height: h})

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} ->
        nil

      %ExRatatui.Event.Key{code: "q", kind: "press"} when state.screen === :category_select ->
        nil

      event ->
        handle_event(terminal, state, event)
    end
  end

  defp handle_event(terminal, %{screen: :category_select} = state, event) do
    categories = CommandRegistry.categories()

    case event do
      %ExRatatui.Event.Key{code: "up", kind: "press"} ->
        new_idx = max(state.category_selected - 1, 0)
        wizard_loop(terminal, %{state | category_selected: new_idx})

      %ExRatatui.Event.Key{code: "down", kind: "press"} ->
        new_idx = min(state.category_selected + 1, length(categories) - 1)
        wizard_loop(terminal, %{state | category_selected: new_idx})

      %ExRatatui.Event.Key{code: "/", kind: "press"} ->
        new_state = %{
          state
          | screen: {:search_overlay, "", :category_select},
            search_query: "",
            search_selected: 0
        }

        wizard_loop(terminal, new_state)

      %ExRatatui.Event.Key{code: "enter", kind: "press"} ->
        category = Enum.at(categories, state.category_selected)

        if is_nil(category) do
          wizard_loop(terminal, state)
        else
          new_state = %{state | screen: {:command_select, category}, command_selected: 0}
          wizard_loop(terminal, new_state)
        end

      _ ->
        wizard_loop(terminal, state)
    end
  end

  defp handle_event(terminal, %{screen: {:command_select, category}} = state, event) do
    commands = CommandRegistry.commands_for_category(category)

    case event do
      %ExRatatui.Event.Key{code: "up", kind: "press"} ->
        new_idx = max(state.command_selected - 1, 0)
        wizard_loop(terminal, %{state | command_selected: new_idx})

      %ExRatatui.Event.Key{code: "down", kind: "press"} ->
        new_idx = min(state.command_selected + 1, length(commands) - 1)
        wizard_loop(terminal, %{state | command_selected: new_idx})

      %ExRatatui.Event.Key{code: "/", kind: "press"} ->
        new_state = %{
          state
          | screen: {:search_overlay, "", {:command_select, category}},
            search_query: "",
            search_selected: 0
        }

        wizard_loop(terminal, new_state)

      %ExRatatui.Event.Key{code: key, kind: "press"} when key in ["b", "backspace"] ->
        wizard_loop(terminal, %{state | screen: :category_select})

      %ExRatatui.Event.Key{code: "esc", kind: "press"} ->
        wizard_loop(terminal, %{state | screen: :category_select})

      %ExRatatui.Event.Key{code: "enter", kind: "press"} ->
        command = Enum.at(commands, state.command_selected)

        if is_nil(command) do
          wizard_loop(terminal, state)
        else
          command
        end

      _ ->
        wizard_loop(terminal, state)
    end
  end

  defp handle_event(terminal, %{screen: {:search_overlay, query, return_screen}} = state, event) do
    results = CommandRegistry.search(query)

    case event do
      %ExRatatui.Event.Key{code: "esc", kind: "press"} ->
        wizard_loop(terminal, %{state | screen: return_screen})

      %ExRatatui.Event.Key{code: "up", kind: "press"} ->
        new_idx = max(state.search_selected - 1, 0)
        wizard_loop(terminal, %{state | search_selected: new_idx})

      %ExRatatui.Event.Key{code: "down", kind: "press"} ->
        new_idx = min(state.search_selected + 1, max(length(results) - 1, 0))
        wizard_loop(terminal, %{state | search_selected: new_idx})

      %ExRatatui.Event.Key{code: "enter", kind: "press"} ->
        command = Enum.at(results, state.search_selected)

        if is_nil(command) do
          wizard_loop(terminal, %{state | screen: return_screen})
        else
          command
        end

      %ExRatatui.Event.Key{code: "backspace", kind: "press"} ->
        new_query = if byte_size(query) > 0, do: String.slice(query, 0..-2//1), else: ""

        new_state = %{
          state
          | screen: {:search_overlay, new_query, return_screen},
            search_query: new_query,
            search_selected: 0
        }

        wizard_loop(terminal, new_state)

      %ExRatatui.Event.Key{code: key, kind: "press"} when byte_size(key) === 1 ->
        new_query = query <> key

        new_state = %{
          state
          | screen: {:search_overlay, new_query, return_screen},
            search_query: new_query,
            search_selected: 0
        }

        wizard_loop(terminal, new_state)

      _ ->
        wizard_loop(terminal, state)
    end
  end

  defp handle_event(terminal, state, _event) do
    wizard_loop(terminal, state)
  end

  defp execute_with_values(command, values) do
    args = CommandRegistry.args_to_cli_list(command, values)
    cli_string = build_cli_string(command.task, args)

    IO.write(IO.ANSI.clear())
    IO.write(IO.ANSI.home())

    Mix.shell().info([:cyan, "\nRunning: ", :reset, :bright, "mix #{cli_string}", :reset, "\n"])

    Mix.Task.run(command.task, args)

    :ok
  end

  defp run_selected_command(command) do
    case Form.run(command) do
      :cancelled -> :ok
      {:ok, values} -> execute_with_values(command, values)
    end
  end

  defp build_cli_string(task, args) do
    if Enum.empty?(args) do
      task
    else
      "#{task} #{Enum.join(args, " ")}"
    end
  end

  defp draw(terminal, state) do
    area = %Rect{x: 0, y: 0, width: state.width, height: state.height}

    [header_area, content_area, footer_area] =
      Layout.split(area, :vertical, [
        {:length, 3},
        {:min, 3},
        {:length, 1}
      ])

    header = %Widgets.Paragraph{
      text: "  DeployEx Wizard  —  ↑↓ navigate  Enter select  / search",
      style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Widgets.Block{
        borders: [:bottom],
        border_style: %Style{fg: :blue}
      }
    }

    {content_widgets, footer_text} = build_screen_content(state, content_area)

    footer = %Widgets.Paragraph{
      text: " #{footer_text}",
      style: %Style{fg: :white, modifiers: [:dim]}
    }

    ExRatatui.draw(terminal, [{header, header_area}, {footer, footer_area}] ++ content_widgets)
  end

  defp build_screen_content(%{screen: :category_select} = state, content_area) do
    categories = CommandRegistry.categories()

    items =
      Enum.map(categories, fn cat ->
        count = length(CommandRegistry.commands_for_category(cat))
        "#{cat}  (#{count} commands)"
      end)

    widget = %Widgets.List{
      items: items,
      selected: state.category_selected,
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      highlight_symbol: " ▸ ",
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: " Categories ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    {[{widget, content_area}], "↑↓ navigate  Enter select  / search  q quit"}
  end

  defp build_screen_content(%{screen: {:command_select, category}} = state, content_area) do
    commands = CommandRegistry.commands_for_category(category)

    items =
      Enum.map(commands, fn cmd ->
        shortdoc = CommandRegistry.shortdoc_for(cmd)
        task_short = String.replace_prefix(cmd.task, "#{String.downcase(category)}.", "")
        "#{String.pad_trailing(task_short, 32)}  #{shortdoc}"
      end)

    widget = %Widgets.List{
      items: items,
      selected: state.command_selected,
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      highlight_symbol: " ▸ ",
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: " #{category} Commands ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    {[{widget, content_area}], "↑↓ navigate  Enter select  / search  b/Esc back"}
  end

  defp build_screen_content(%{screen: {:search_overlay, query, _return}} = state, content_area) do
    results = CommandRegistry.search(query)

    items =
      Enum.map(results, fn cmd ->
        shortdoc = CommandRegistry.shortdoc_for(cmd)
        category_tag = String.pad_trailing("[#{cmd.category}]", 14)
        "#{category_tag}  #{String.pad_trailing(cmd.task, 40)}  #{shortdoc}"
      end)

    search_display = if query === "", do: " (type to search...)", else: " #{query}█"

    [search_area, results_area] =
      Layout.split(content_area, :vertical, [
        {:length, 3},
        {:min, 3}
      ])

    search_widget = %Widgets.Paragraph{
      text: search_display,
      style: %Style{fg: :yellow},
      block: %Widgets.Block{
        title: " / Search Commands ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :yellow}
      }
    }

    results_widget = %Widgets.List{
      items: items,
      selected: state.search_selected,
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      highlight_symbol: " ▸ ",
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: " Results (#{length(results)}) ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    {[{search_widget, search_area}, {results_widget, results_area}],
     "↑↓ navigate  Enter run  Backspace delete char  Esc cancel search"}
  end

  defp build_screen_content(_state, content_area) do
    widget = %Widgets.Paragraph{
      text: "Loading...",
      style: %Style{fg: :yellow},
      alignment: :center
    }

    {[{widget, content_area}], ""}
  end
end
