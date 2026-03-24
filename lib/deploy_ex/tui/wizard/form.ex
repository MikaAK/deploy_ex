defmodule DeployEx.TUI.Wizard.Form do
  alias DeployEx.TUI.Wizard.CommandRegistry
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

  @type result :: {:ok, keyword()} | :cancelled

  @spec run(CommandRegistry.command_def()) :: result()
  def run(command) do
    if DeployEx.TUI.enabled?() do
      ExRatatui.run(fn terminal ->
        {width, height} = ExRatatui.terminal_size()
        run_in_terminal(terminal, width, height, command)
      end)
    else
      run_console(command)
    end
  end

  @spec run_in_terminal(ExRatatui.terminal_ref(), non_neg_integer(), non_neg_integer(), CommandRegistry.command_def()) :: result()
  def run_in_terminal(terminal, width, height, command) do
    shortdoc = CommandRegistry.shortdoc_for(command)

    initial_state = %{
      command: command,
      shortdoc: shortdoc,
      focused: 0,
      values: initial_values(command.inputs),
      text_buffers: initial_text_buffers(command.inputs),
      error: nil
    }

    form_loop(terminal, width, height, initial_state)
  end

  defp run_console(%{inputs: []} = _command), do: {:ok, []}

  defp run_console(command) do
    shortdoc = CommandRegistry.shortdoc_for(command)
    Mix.shell().info([:cyan, "\n#{command.task}", :reset, " — #{shortdoc}"])
    Mix.shell().info([:faint, "Fill in the options below (press Enter to skip optional fields)\n"])

    result =
      Enum.reduce_while(command.inputs, [], fn input, acc ->
        value = prompt_console_input(input)

        case value do
          :cancelled -> {:halt, :cancelled}
          nil -> {:cont, acc}
          val -> {:cont, [{input.key, val} | acc]}
        end
      end)

    case result do
      :cancelled -> :cancelled
      values -> {:ok, Enum.reverse(values)}
    end
  end

  defp prompt_console_input(%{type: :boolean} = input) do
    label = format_console_label(input)
    raw = label |> Mix.shell().prompt() |> String.trim() |> String.downcase()

    cond do
      raw in ["y", "yes", "true", "1"] -> true
      raw in ["n", "no", "false", "0", ""] -> false
      true -> false
    end
  end

  defp prompt_console_input(%{type: :select, choices_fn: choices_fn} = input) when not is_nil(choices_fn) do
    choices = choices_fn.()

    if Enum.empty?(choices) do
      label = format_console_label(input)
      raw = label |> Mix.shell().prompt() |> String.trim()
      if raw === "" and not input.required, do: nil, else: raw
    else
      Enum.each(Enum.with_index(choices), fn {choice, idx} ->
        Mix.shell().info("  #{idx}) #{choice}")
      end)

      label = format_console_label(input)
      raw = label |> Mix.shell().prompt() |> String.trim()

      cond do
        raw === "" and not input.required -> nil
        String.match?(raw, ~r/^\d+$/) ->
          idx = String.to_integer(raw)
          Enum.at(choices, idx) || raw
        true -> raw
      end
    end
  end

  defp prompt_console_input(%{type: :integer} = input) do
    label = format_console_label(input)
    raw = label |> Mix.shell().prompt() |> String.trim()

    cond do
      raw === "" and not input.required -> nil
      raw === "" -> prompt_console_input(input)
      true ->
        case Integer.parse(raw) do
          {num, ""} -> num
          _ -> prompt_console_input(input)
        end
    end
  end

  defp prompt_console_input(input) do
    label = format_console_label(input)
    raw = label |> Mix.shell().prompt() |> String.trim()

    if raw === "" and not input.required, do: nil, else: raw
  end

  defp format_console_label(input) do
    required_marker = if input.required, do: " *", else: ""
    default_hint = if not is_nil(input.default), do: " [#{input.default}]", else: ""
    "#{input.label}#{required_marker}#{default_hint}: "
  end

  defp initial_values(inputs) do
    Map.new(inputs, fn input ->
      default = if is_nil(input.default) do
        case input.type do
          :boolean -> false
          _ -> nil
        end
      else
        input.default
      end

      {input.key, default}
    end)
  end

  defp initial_text_buffers(inputs) do
    Map.new(inputs, fn input ->
      default_str = if is_nil(input.default), do: "", else: to_string(input.default)
      {input.key, default_str}
    end)
  end

  defp form_loop(terminal, width, height, state) do
    draw_form(terminal, width, height, state)
    inputs = state.command.inputs

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        form_loop(terminal, new_width, new_height, state)

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} ->
        :cancelled

      %ExRatatui.Event.Key{code: "esc", kind: "press"} ->
        :cancelled

      %ExRatatui.Event.Key{code: "up", kind: "press"} ->
        new_focused = max(state.focused - 1, 0)
        form_loop(terminal, width, height, %{state | focused: new_focused, error: nil})

      %ExRatatui.Event.Key{code: "down", kind: "press"} ->
        new_focused = min(state.focused + 1, length(inputs) - 1)
        form_loop(terminal, width, height, %{state | focused: new_focused, error: nil})

      %ExRatatui.Event.Key{code: "tab", kind: "press"} ->
        new_focused = rem(state.focused + 1, max(length(inputs), 1))
        form_loop(terminal, width, height, %{state | focused: new_focused, error: nil})

      %ExRatatui.Event.Key{code: "enter", kind: "press"} ->
        current_input = Enum.at(inputs, state.focused)
        handle_enter(terminal, width, height, state, current_input, inputs)

      %ExRatatui.Event.Key{code: " ", kind: "press"} ->
        current_input = Enum.at(inputs, state.focused)
        new_state = maybe_toggle_boolean(state, current_input)
        form_loop(terminal, width, height, new_state)

      %ExRatatui.Event.Key{code: "backspace", kind: "press"} ->
        current_input = Enum.at(inputs, state.focused)
        new_state = handle_backspace(state, current_input)
        form_loop(terminal, width, height, new_state)

      %ExRatatui.Event.Key{code: key, kind: "press"} when byte_size(key) === 1 ->
        current_input = Enum.at(inputs, state.focused)
        new_state = handle_char(state, current_input, key)
        form_loop(terminal, width, height, new_state)

      _ ->
        form_loop(terminal, width, height, state)
    end
  end

  defp handle_enter(terminal, width, height, state, current_input, inputs) do
    cond do
      current_input.type === :boolean ->
        new_state = maybe_toggle_boolean(state, current_input)

        if state.focused === length(inputs) - 1 do
          maybe_submit(terminal, width, height, new_state)
        else
          new_focused = min(state.focused + 1, length(inputs) - 1)
          form_loop(terminal, width, height, %{new_state | focused: new_focused})
        end

      current_input.type === :select ->
        handle_select_input(terminal, width, height, state, current_input, inputs)

      state.focused === length(inputs) - 1 ->
        maybe_submit(terminal, width, height, state)

      true ->
        new_focused = min(state.focused + 1, length(inputs) - 1)
        form_loop(terminal, width, height, %{state | focused: new_focused})
    end
  end

  defp handle_select_input(terminal, width, height, state, current_input, inputs) do
    choices_fn = current_input.choices_fn

    if is_nil(choices_fn) do
      new_focused = min(state.focused + 1, length(inputs) - 1)
      form_loop(terminal, width, height, %{state | focused: new_focused})
    else
      choices = choices_fn.()

      if Enum.empty?(choices) do
        new_focused = min(state.focused + 1, length(inputs) - 1)
        form_loop(terminal, width, height, %{state | focused: new_focused})
      else
        result = DeployEx.TUI.Select.run_in_terminal(terminal, choices,
          title: current_input.label,
          allow_all: false
        )

        case result do
          [selected] ->
            new_values = Map.put(state.values, current_input.key, selected)
            new_buffers = Map.put(state.text_buffers, current_input.key, selected)
            new_focused = min(state.focused + 1, length(inputs) - 1)
            form_loop(terminal, width, height, %{state | values: new_values, text_buffers: new_buffers, focused: new_focused})

          [] ->
            form_loop(terminal, width, height, state)
        end
      end
    end
  end

  defp maybe_submit(terminal, width, height, state) do
    state
    |> commit_text_buffers()
    |> validate_and_build_result()
    |> case do
      {:ok, _values} = result ->
        result

      {:error, missing} ->
        error_msg = "Required: #{Enum.join(missing, ", ")}"
        form_loop(terminal, width, height, %{state | error: error_msg})
    end
  end

  defp commit_text_buffers(state) do
    inputs = state.command.inputs

    updated_values =
      Enum.reduce(inputs, state.values, fn input, acc ->
        case input.type do
          type when type in [:string, :integer] ->
            buf = Map.get(state.text_buffers, input.key, "")

            cond do
              buf === "" -> acc
              type === :integer ->
                case Integer.parse(buf) do
                  {num, ""} -> Map.put(acc, input.key, num)
                  _ -> acc
                end
              true -> Map.put(acc, input.key, buf)
            end

          _ -> acc
        end
      end)

    %{state | values: updated_values}
  end

  defp validate_and_build_result(state) do
    inputs = state.command.inputs

    missing =
      inputs
      |> Enum.filter(& &1.required)
      |> Enum.reject(fn input ->
        val = Map.get(state.values, input.key)
        not is_nil(val) and val !== "" and val !== false
      end)
      |> Enum.map(& &1.label)

    if Enum.empty?(missing) do
      result =
        inputs
        |> Enum.reduce([], fn input, acc ->
          val = Map.get(state.values, input.key)

          cond do
            is_nil(val) -> acc
            val === false and input.type === :boolean -> acc
            val === "" -> acc
            true -> [{input.key, val} | acc]
          end
        end)
        |> Enum.reverse()

      {:ok, result}
    else
      {:error, missing}
    end
  end

  defp maybe_toggle_boolean(state, %{type: :boolean} = input) do
    current = Map.get(state.values, input.key, false)
    %{state | values: Map.put(state.values, input.key, !current)}
  end

  defp maybe_toggle_boolean(state, _input), do: state

  defp handle_backspace(state, %{type: type} = input) when type in [:string, :integer, :select] do
    buf = Map.get(state.text_buffers, input.key, "")
    new_buf = if byte_size(buf) > 0, do: String.slice(buf, 0..-2//1), else: ""
    new_values = if new_buf === "", do: Map.put(state.values, input.key, nil), else: Map.put(state.values, input.key, new_buf)
    %{state | text_buffers: Map.put(state.text_buffers, input.key, new_buf), values: new_values}
  end

  defp handle_backspace(state, _input), do: state

  defp handle_char(state, %{type: type} = input, char) when type in [:string, :integer, :select] do
    buf = Map.get(state.text_buffers, input.key, "")
    new_buf = buf <> char
    new_values = Map.put(state.values, input.key, new_buf)
    %{state | text_buffers: Map.put(state.text_buffers, input.key, new_buf), values: new_values}
  end

  defp handle_char(state, _input, _char), do: state

  defp draw_form(terminal, width, height, state) do
    area = %Rect{x: 0, y: 0, width: width, height: height}
    inputs = state.command.inputs

    [header_area, content_area, footer_area] = Layout.split(area, :vertical, [
      {:length, 3},
      {:min, 3},
      {:length, 2}
    ])

    [_pad_l, inner_area, _pad_r] = Layout.split(content_area, :horizontal, [
      {:length, 2},
      {:min, 10},
      {:length, 2}
    ])

    header_text = "  mix #{state.command.task}  —  #{state.shortdoc}"

    header = %Widgets.Paragraph{
      text: header_text,
      style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Widgets.Block{
        borders: [:bottom],
        border_style: %Style{fg: :blue}
      }
    }

    input_lines = build_input_lines(inputs, state)
    content_text = Enum.join(input_lines, "\n")

    error_suffix = if state.error, do: "\n\n  ✗ #{state.error}", else: ""

    content = %Widgets.Paragraph{
      text: content_text <> error_suffix,
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: " Options ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    has_required = Enum.any?(inputs, & &1.required)
    required_note = if has_required, do: "  * = required  ", else: ""

    footer_text = "#{required_note}↑↓/Tab navigate  Space toggle  Enter confirm  Esc cancel"

    footer = %Widgets.Paragraph{
      text: footer_text,
      style: %Style{fg: :white, modifiers: [:dim]}
    }

    ExRatatui.draw(terminal, [
      {header, header_area},
      {content, inner_area},
      {footer, footer_area}
    ])
  end

  defp build_input_lines(inputs, state) do
    Enum.with_index(inputs)
    |> Enum.map(fn {input, idx} ->
      focused? = idx === state.focused
      value = Map.get(state.values, input.key)
      buf = Map.get(state.text_buffers, input.key, "")

      prefix = if focused?, do: " ▸ ", else: "   "
      required_marker = if input.required, do: "*", else: " "

      value_display = format_value_display(input, value, buf, focused?)

      "#{prefix}#{required_marker} #{String.pad_trailing(input.label, 22)} #{value_display}"
    end)
  end

  defp format_value_display(%{type: :boolean}, value, _buf, _focused?) do
    if value, do: "[✓ yes]", else: "[ no ]"
  end

  defp format_value_display(%{type: :select}, _value, buf, focused?) do
    display = if buf === "", do: "(select...)", else: buf
    if focused?, do: "▸ #{display}", else: "  #{display}"
  end

  defp format_value_display(_input, _value, buf, focused?) do
    if focused? do
      if buf === "", do: "█", else: "#{buf}█"
    else
      if buf === "", do: "—", else: buf
    end
  end
end
