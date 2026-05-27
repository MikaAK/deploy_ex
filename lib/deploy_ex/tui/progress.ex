defmodule DeployEx.TUI.Progress do
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

  @log_buffer_max 500
  @ansi_regex ~r/\x1b\[[\d;]*[a-zA-Z]/
  @ansi_sgr_regex ~r/\x1b\[([\d;]*)m/

  @type step :: {String.t(), (-> :ok | {:ok, term()} | {:error, term()})}

  @spec run_steps(list(step()), keyword()) :: :ok | {:error, term()}
  def run_steps(steps, opts \\ []) do
    if DeployEx.TUI.enabled?() do
      run_steps_tui(steps, opts)
    else
      run_steps_console(steps, opts)
    end
  end

  defp run_steps_console(steps, opts) do
    title = Keyword.get(opts, :title, "Progress")
    total = length(steps)

    Mix.shell().info([:cyan, "#{title}"])

    steps
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {{label, fun}, index}, _acc ->
        Mix.shell().info([:faint, "  [#{index}/#{total}] ", :reset, label])

        case fun.() do
          :ok -> {:cont, :ok}
          {:ok, _} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
  end

  defp run_steps_tui(steps, opts) do
    title = Keyword.get(opts, :title, "Progress")
    total = length(steps)

    {result, completed_steps} = DeployEx.TUI.run(fn terminal ->
      {width, height} = ExRatatui.terminal_size()
      execute_steps(terminal, width, height, title, steps, total, 0, [])
    end)

    print_steps_after_tui(title, completed_steps, result)

    result
  end

  defp execute_steps(terminal, width, height, title, [], total, _index, completed) do
    draw_progress(terminal, width, height, title, "Complete!", 1.0, total, total)
    Process.sleep(500)
    {:ok, Enum.reverse(completed)}
  end

  defp execute_steps(terminal, width, height, title, [{label, fun} | rest], total, index, completed) do
    ratio = index / total
    task = Task.async(fun)

    case await_step(terminal, width, height, title, label, ratio, total, index, task, false) do
      {:ok, new_width, new_height} ->
        execute_steps(terminal, new_width, new_height, title, rest, total, index + 1, [{label, :ok} | completed])

      {:cancelled, _new_width, _new_height} ->
        {{:error, :cancelled}, Enum.reverse([{label, :cancelled} | completed])}

      {{:error, _} = error, new_width, new_height} ->
        draw_error(terminal, new_width, new_height, title, "Failed", error)
        Process.sleep(1500)
        {error, Enum.reverse([{label, :failed} | completed])}
    end
  end

  defp await_step(terminal, width, height, title, label, ratio, total, index, task, cancelling?) do
    display_label = if cancelling?, do: label <> "  [Ctrl-C again to cancel]", else: label
    draw_progress(terminal, width, height, title, display_label, ratio, total, index)

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        await_step(terminal, new_width, new_height, title, label, ratio, total, index, task, cancelling?)

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} when not cancelling? ->
        await_step(terminal, width, height, title, label, ratio, total, index, task, true)

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} when cancelling? ->
        Task.shutdown(task, :brutal_kill)
        {:cancelled, width, height}

      _ ->
        case Task.yield(task, 0) do
          {:ok, :ok} -> {:ok, width, height}
          {:ok, {:ok, _}} -> {:ok, width, height}
          {:ok, {:error, _} = error} -> {error, width, height}
          {:exit, reason} -> {{:error, reason}, width, height}
          nil -> await_step(terminal, width, height, title, label, ratio, total, index, task, cancelling?)
        end
    end
  end

  defp print_steps_after_tui(title, completed_steps, result) do
    {status_label, header_color} = case result do
      :ok -> {"OK", :green}
      {:error, :cancelled} -> {"CANCELLED", :yellow}
      _ -> {"FAILED", :red}
    end

    Mix.shell().info([
      header_color, "\n#{String.duplicate("=", 60)}",
      header_color, "\n#{title} [#{status_label}]",
      header_color, "\n#{String.duplicate("=", 60)}", :reset
    ])

    Enum.each(completed_steps, fn {label, status} ->
      case status do
        :ok -> Mix.shell().info([:green, "  ✓ ", :reset, label])
        :failed -> Mix.shell().info([:red, "  ✗ ", :reset, label])
        :cancelled -> Mix.shell().info([:yellow, "  ○ ", :reset, label])
      end
    end)

    case result do
      {:error, :cancelled} -> :ok
      {:error, error} -> Mix.shell().error("\n  Error: #{format_step_error(error)}")
      _ -> :ok
    end

    Mix.shell().info("")
  end

  defp format_step_error({:error, %ErrorMessage{} = error}), do: ErrorMessage.to_string(error)
  defp format_step_error({:error, error}) when is_binary(error), do: error
  defp format_step_error({:error, error}), do: inspect(error)
  defp format_step_error(error), do: inspect(error)

  @spec run_stream(String.t(), (pid() -> term()), keyword()) :: term()
  def run_stream(title, work_fn, opts \\ []) do
    if DeployEx.TUI.enabled?() do
      run_stream_tui(title, work_fn, opts)
    else
      run_stream_console(title, work_fn)
    end
  end

  @doc """
  Like `run_stream/3` but returns `{result, log_tail, ansible_setup_log}` so
  callers can format captured log output into the final summary. Both lists
  are newest-first. `ansible_setup_log` is uncapped — it only collects lines
  routed through `update_ansible_log/2` and isn't subject to the rolling
  `@log_buffer_max` cap that protects the live UI buffer.
  """
  def run_stream_with_log(title, work_fn, opts \\ []) do
    if DeployEx.TUI.enabled?() do
      run_stream_tui_with_log(title, work_fn, opts)
    else
      run_stream_console_with_log(title, work_fn)
    end
  end

  defp run_stream_tui_with_log(title, work_fn, opts) do
    {result, log_tail, ansible_setup_log} =
      DeployEx.TUI.run(fn terminal ->
        stream_in_terminal(terminal, title, work_fn, opts)
      end)

    {result, log_tail, ansible_setup_log}
  end

  defp run_stream_console_with_log(title, work_fn) do
    caller = self()
    Mix.shell().info([:cyan, title])

    worker =
      spawn_link(fn ->
        result = work_fn.(caller)
        send(caller, {:tui_progress_done, result})
      end)

    console_stream_loop_with_log(title, worker, [], [])
  end

  defp console_stream_loop_with_log(title, worker, log_tail, ansible_setup_log) do
    receive do
      {:tui_progress_update, ratio, label} ->
        percent = round(ratio * 100)
        Mix.shell().info([:faint, "  [#{percent}%] ", :reset, label])
        console_stream_loop_with_log(title, worker, log_tail, ansible_setup_log)

      {:tui_progress_log, line} when is_binary(line) ->
        IO.puts(line)
        console_stream_loop_with_log(title, worker, [line | log_tail], ansible_setup_log)

      {:tui_progress_log, {_color, _text} = entry} ->
        {_color, text} = entry
        Mix.shell().info([:faint, text])
        console_stream_loop_with_log(title, worker, [entry | log_tail], ansible_setup_log)

      {:tui_progress_ansible_log, text} ->
        IO.puts(text)
        console_stream_loop_with_log(title, worker, log_tail, [text | ansible_setup_log])

      {:tui_progress_confirm_request, payload, reply_to} ->
        if payload[:preview], do: Mix.shell().info(payload.preview)
        choice = if Mix.shell().yes?(payload.prompt), do: :yes, else: :no
        send(reply_to, {:tui_progress_confirm_response, choice})
        console_stream_loop_with_log(title, worker, log_tail, ansible_setup_log)

      {:tui_progress_done, result} ->
        Mix.shell().info([:green, "  ✓ #{title} complete"])
        {result, log_tail, ansible_setup_log}
    end
  end

  defp run_stream_console(title, work_fn) do
    caller = self()
    Mix.shell().info([:cyan, title])

    worker = spawn_link(fn ->
      result = work_fn.(caller)
      send(caller, {:tui_progress_done, result})
    end)

    console_stream_loop(title, worker)
  end

  defp console_stream_loop(title, worker) do
    receive do
      {:tui_progress_update, ratio, label} ->
        percent = round(ratio * 100)
        Mix.shell().info([:faint, "  [#{percent}%] ", :reset, label])
        console_stream_loop(title, worker)

      {:tui_progress_log, line} when is_binary(line) ->
        IO.puts(line)
        console_stream_loop(title, worker)

      {:tui_progress_log, {_color, text}} ->
        Mix.shell().info([:faint, text])
        console_stream_loop(title, worker)

      {:tui_progress_ansible_log, text} ->
        IO.puts(text)
        console_stream_loop(title, worker)

      {:tui_progress_confirm_request, payload, reply_to} ->
        if payload[:preview], do: Mix.shell().info(payload.preview)
        choice = if Mix.shell().yes?(payload.prompt), do: :yes, else: :no
        send(reply_to, {:tui_progress_confirm_response, choice})
        console_stream_loop(title, worker)

      {:tui_progress_done, result} ->
        Mix.shell().info([:green, "  ✓ #{title} complete"])
        result
    end
  end

  defp run_stream_tui(title, work_fn, opts) do
    {result, _log_tail, _ansible_setup_log} =
      DeployEx.TUI.run(fn terminal ->
        stream_in_terminal(terminal, title, work_fn, opts)
      end)

    result
  end

  @doc """
  Runs the streaming progress loop inside an already-open `ExRatatui` terminal.

  Returns `{result, log_tail, ansible_setup_log}`:
    * `result` — whatever `work_fn/1` returned
    * `log_tail` — capped, rolling output pane buffer (newest-first)
    * `ansible_setup_log` — uncapped capture from `update_ansible_log/2`
      (newest-first), so callers can show the full setup transcript in the
      final summary regardless of `@log_buffer_max` rollover.
  """
  @spec stream_in_terminal(term(), String.t(), (pid() -> term()), keyword()) ::
          {term(), [term()], [String.t()]}
  def stream_in_terminal(terminal, title, work_fn, opts \\ []) do
    {width, height} = ExRatatui.terminal_size()
    caller = self()

    state = %{
      ratio: 0.0,
      label: "Starting...",
      status: :running,
      result: nil,
      cancelling: false,
      log_tail: [],
      log_offset: 0,
      ansible_setup_log: [],
      mode: :log
    }

    worker = spawn_link(fn ->
      result = work_fn.(caller)
      send(caller, {:tui_progress_done, result})
    end)

    stream_loop(terminal, width, height, title, state, worker, opts)
  end

  @doc """
  Prints the captured log tail to stderr when the streamed work returned an
  error. No-op on success. Must be called AFTER the TUI has exited.
  """
  def print_log_tail_on_error({:error, _}, [_ | _] = log_tail) do
    tail_count = min(50, length(log_tail))

    Mix.shell().error("\n────── last #{tail_count} log lines ──────")

    log_tail
    |> Enum.take(tail_count)
    |> Enum.reverse()
    |> Enum.each(fn {_color, text} -> Mix.shell().error(text) end)

    Mix.shell().error("────── end log ──────\n")
  end
  def print_log_tail_on_error(_result, _log_tail), do: :ok

  def update_progress(tui_pid, ratio, label) do
    send(tui_pid, {:tui_progress_update, ratio, label})
  end

  @type confirm_payload :: String.t() | %{prompt: String.t(), preview: String.t() | nil}

  @doc """
  Synchronously prompts the user for a yes/no confirmation in the lower pane
  of the streaming progress UI. Returns `:yes` or `:no`.

  Accepts either a plain string prompt or a map `%{prompt, preview}` where
  `preview` is unified-diff text rendered above the keys.

  In TUI mode, the log pane is replaced with a confirmation widget showing
  the (wrapped) prompt + optional preview. The progress gauge stays visible
  at the top. Y/N keys are intercepted while the prompt is active.

  In console mode (no TUI), falls back to printing the preview to stderr and
  using `Mix.shell().yes?/1`.
  """
  @spec confirm(pid() | nil, confirm_payload()) :: :yes | :no
  def confirm(tui_pid, prompt) when is_binary(prompt) do
    confirm(tui_pid, %{prompt: prompt, preview: nil})
  end

  def confirm(tui_pid, %{prompt: prompt} = payload) when is_pid(tui_pid) do
    emit_confirm_log_hints(tui_pid, payload)
    send(tui_pid, {:tui_progress_confirm_request, payload, self()})

    receive do
      {:tui_progress_confirm_response, choice} ->
        emit_confirm_choice_log(tui_pid, prompt, choice)
        choice
    end
  end

  def confirm(_tui_pid, %{prompt: prompt} = payload) do
    if payload[:preview], do: Mix.shell().info(payload.preview)
    if Mix.shell().yes?(prompt), do: :yes, else: :no
  end

  defp emit_confirm_log_hints(tui_pid, %{prompt: prompt, preview: preview}) do
    update_log(tui_pid, IO.ANSI.format(["  ", :yellow, "▶ #{prompt}", :reset], true))

    if is_binary(preview) and preview !== "" do
      preview
      |> String.split("\n", trim: false)
      |> Enum.each(fn line ->
        update_log(tui_pid, IO.ANSI.format(["    ", :light_black, line, :reset], true))
      end)
    end

    update_log(
      tui_pid,
      IO.ANSI.format(["  ", :cyan, "▶ Press [Y]es to apply or [N]o to skip", :reset], true)
    )
  end

  defp emit_confirm_choice_log(tui_pid, _prompt, :yes) do
    update_log(tui_pid, IO.ANSI.format(["  ", :green, "✓ Accepted", :reset], true))
  end

  defp emit_confirm_choice_log(tui_pid, _prompt, :no) do
    update_log(tui_pid, IO.ANSI.format(["  ", :yellow, "✗ Skipped", :reset], true))
  end

  @doc """
  Streams a single log line into the TUI's log pane. The line's first SGR
  color code is detected and preserved as the rendered foreground color;
  remaining ANSI escapes are stripped and long lines are truncated to fit
  the pane width at draw time.
  """
  def update_log(tui_pid, line) do
    if DeployEx.TUI.enabled?() do
      send(tui_pid, {:tui_progress_log, parse_log_line(line)})
    else
      send(tui_pid, {:tui_progress_log, to_string(line)})
    end
  end

  @doc """
  Streams a log line that should be captured into the dedicated ansible
  setup transcript in addition to the rolling log pane. The transcript
  isn't subject to `@log_buffer_max`, so the full setup output survives
  for the post-run summary even for very long playbooks.
  """
  def update_ansible_log(tui_pid, line) when is_pid(tui_pid) do
    raw = to_string(line)

    if DeployEx.TUI.enabled?() do
      stripped = raw |> String.replace(@ansi_regex, "") |> String.trim_trailing()
      send(tui_pid, {:tui_progress_ansible_log, stripped})
    else
      send(tui_pid, {:tui_progress_ansible_log, String.trim_trailing(raw)})
    end
  end

  def update_ansible_log(_tui_pid, _line), do: :ok

  defp parse_log_line(line) do
    text = to_string(line)
    color = detect_line_color(text)
    plain = text |> String.replace(@ansi_regex, "") |> String.trim_trailing()
    {color, plain}
  end

  defp detect_line_color(text) do
    case Regex.run(@ansi_sgr_regex, text, capture: :all_but_first) do
      nil -> nil
      [params] -> sgr_params_to_color(params)
    end
  end

  defp sgr_params_to_color(params) do
    codes = String.split(params, ";")

    cond do
      "31" in codes -> :red
      "32" in codes -> :green
      "33" in codes -> :yellow
      "34" in codes -> :blue
      "35" in codes -> :magenta
      "36" in codes -> :cyan
      "91" in codes -> :light_red
      "92" in codes -> :light_green
      "93" in codes -> :light_yellow
      "94" in codes -> :light_blue
      "95" in codes -> :light_magenta
      "96" in codes -> :light_cyan
      true -> nil
    end
  end

  defp stream_loop(terminal, width, height, title, state, worker, opts) do
    draw_stream_progress(terminal, width, height, title, state)

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        stream_loop(terminal, new_width, new_height, title, state, worker, opts)

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} when not state.cancelling ->
        stream_loop(terminal, width, height, title, %{state | cancelling: true}, worker, opts)

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} when state.cancelling ->
        Process.exit(worker, :kill)
        {{:error, :cancelled}, state.log_tail}

      %ExRatatui.Event.Key{code: code, kind: "press"} = ev ->
        case handle_key(state, code, modifier_list(ev), height) do
          {:handled, new_state} ->
            stream_loop(terminal, width, height, title, new_state, worker, opts)

          :ignore ->
            drain_worker_messages(terminal, width, height, title, state, worker, opts)
        end

      _ ->
        drain_worker_messages(terminal, width, height, title, state, worker, opts)
    end
  end

  defp handle_key(state, code, mods, height) do
    case maybe_handle_confirm_key(state, code, mods) do
      {:handled, _} = result -> result
      :ignore -> maybe_handle_scroll_key(state, code, mods, height)
    end
  end

  defp maybe_handle_scroll_key(state, code, [], height) do
    page_step = max(log_page_step(height), 1)

    case code do
      "up" -> {:handled, adjust_log_offset(state, +1)}
      "down" -> {:handled, adjust_log_offset(state, -1)}
      "page_up" -> {:handled, adjust_log_offset(state, +page_step)}
      "page_down" -> {:handled, adjust_log_offset(state, -page_step)}
      "home" -> {:handled, %{state | log_offset: @log_buffer_max}}
      "end" -> {:handled, %{state | log_offset: 0}}
      _ -> :ignore
    end
  end

  defp maybe_handle_scroll_key(_state, _code, _mods, _height), do: :ignore

  defp adjust_log_offset(state, delta) do
    %{state | log_offset: max(state.log_offset + delta, 0)}
  end

  defp log_page_step(total_height), do: div(max(total_height - 5, 4), 2)

  defp drain_worker_messages(terminal, width, height, title, state, worker, opts) do
    receive do
      {:tui_progress_update, ratio, label} ->
        new_state = %{state | ratio: ratio, label: label}
        stream_loop(terminal, width, height, title, new_state, worker, opts)

      {:tui_progress_log, line} ->
        new_state = %{state | log_tail: append_log_line(state.log_tail, line)}
        stream_loop(terminal, width, height, title, new_state, worker, opts)

      {:tui_progress_ansible_log, text} ->
        new_state =
          state
          |> Map.put(:log_tail, append_log_line(state.log_tail, {nil, text}))
          |> Map.put(:ansible_setup_log, [text | state.ansible_setup_log])

        stream_loop(terminal, width, height, title, new_state, worker, opts)

      {:tui_progress_confirm_request, payload, reply_to} ->
        confirm_state = payload |> normalize_confirm_payload() |> Map.put(:reply_to, reply_to)
        new_state = %{state | mode: {:confirm, confirm_state}}
        stream_loop(terminal, width, height, title, new_state, worker, opts)

      {:tui_progress_done, result} ->
        final_state = %{state | ratio: 1.0, label: "Complete!"}
        draw_stream_progress(terminal, width, height, title, final_state)
        Process.sleep(500)
        {result, final_state.log_tail, final_state.ansible_setup_log}
    after
      0 ->
        stream_loop(terminal, width, height, title, state, worker, opts)
    end
  end

  defp modifier_list(%ExRatatui.Event.Key{modifiers: nil}), do: []
  defp modifier_list(%ExRatatui.Event.Key{modifiers: mods}) when is_list(mods), do: mods

  defp maybe_handle_confirm_key(%{mode: {:confirm, %{reply_to: reply_to}}} = state, code, []) do
    case confirm_choice_for_code(code) do
      nil ->
        :ignore

      choice ->
        send(reply_to, {:tui_progress_confirm_response, choice})
        {:handled, %{state | mode: :log}}
    end
  end

  defp maybe_handle_confirm_key(_state, _code, _mods), do: :ignore

  defp confirm_choice_for_code(code) when code in ["y", "Y"], do: :yes
  defp confirm_choice_for_code(code) when code in ["n", "N"], do: :no
  defp confirm_choice_for_code(_), do: nil

  defp normalize_confirm_payload(prompt) when is_binary(prompt) do
    %{prompt: prompt, preview: nil}
  end

  defp normalize_confirm_payload(%{prompt: _} = payload) do
    %{prompt: payload.prompt, preview: payload[:preview]}
  end

  defp append_log_line(log_tail, line) do
    [line | Enum.take(log_tail, @log_buffer_max - 1)]
  end

  defp draw_stream_progress(terminal, width, height, title, state) do
    display_label = stream_display_label(state)
    area = %Rect{x: 0, y: 0, width: width, height: height}

    [top_area, lower_area, footer_area] = Layout.split(area, :vertical, [
      {:length, 4},
      {:min, 3},
      {:length, 1}
    ])

    [gauge_area, label_area] = Layout.split(top_area, :vertical, [
      {:length, 3},
      {:length, 1}
    ])

    lower_widgets = build_lower_widgets(state, lower_area, width)
    footer_widget = build_footer_widget(state)

    base_widgets = [
      {build_gauge_widget(title, state.ratio), gauge_area},
      {build_label_widget(display_label), label_area},
      {footer_widget, footer_area}
    ]

    ExRatatui.draw(terminal, base_widgets ++ lower_widgets)
  end

  defp build_lower_widgets(%{mode: {:confirm, payload}} = state, lower_area, width) do
    confirm_height = confirm_area_height(payload, width, lower_area.height)
    log_height = max(lower_area.height - confirm_height, 3)

    [log_area, confirm_area] =
      Layout.split(lower_area, :vertical, [
        {:length, log_height},
        {:length, confirm_height}
      ])

    build_log_widgets(state.log_tail, log_area, width, state.log_offset) ++
      build_confirm_widgets(payload, confirm_area, width)
  end

  defp build_lower_widgets(state, lower_area, width) do
    build_log_widgets(state.log_tail, lower_area, width, state.log_offset)
  end

  defp confirm_area_height(%{prompt: prompt, preview: preview}, width, lower_height) do
    inner_width = max(width - 8, 20)
    prompt_rows = prompt |> wrap_text(inner_width) |> length()
    preview_rows = preview |> preview_row_count(inner_width)
    separator_row = if preview_rows === 0, do: 0, else: 1
    blank_row = 1
    keys_row = 1
    chrome = 2

    desired = chrome + prompt_rows + separator_row + preview_rows + blank_row + keys_row
    desired |> max(6) |> min(max(lower_height - 4, 6))
  end

  defp preview_row_count(nil, _max_width), do: 0
  defp preview_row_count("", _max_width), do: 0

  defp preview_row_count(preview, max_width) do
    preview
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_text(&1, max_width))
    |> length()
  end

  defp build_confirm_widgets(%{prompt: prompt, preview: preview}, lower_area, width) do
    inner_width = max(width - 4, 20)
    inner_height = max(lower_area.height - 2, 1)
    rect_width = max(lower_area.width - 4, 1)

    styled_lines = build_styled_confirm_lines(prompt, preview, inner_width - 2)
    line_widgets = render_styled_lines(styled_lines, lower_area, rect_width, inner_height)

    [{confirm_block(), lower_area} | line_widgets]
  end

  defp build_styled_confirm_lines(prompt, preview, max_width) do
    prompt_lines = prompt |> wrap_text(max_width) |> Enum.map(&styled(&1, :white, [:bold]))
    preview_lines = build_preview_styled_lines(preview, max_width)
    separator = if preview_lines === [], do: [], else: [styled(separator_text(max_width), :light_black, [])]
    keys = [styled("[Y]es   [N]o", :cyan, [])]

    prompt_lines ++ separator ++ preview_lines ++ [styled("", :white, [])] ++ keys
  end

  defp build_preview_styled_lines(nil, _max_width), do: []
  defp build_preview_styled_lines("", _max_width), do: []

  defp build_preview_styled_lines(preview, max_width) do
    preview
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_text(&1, max_width))
    |> Enum.map(fn line -> styled(line, preview_line_color(line), []) end)
  end

  defp render_styled_lines(styled_lines, lower_area, rect_width, inner_height) do
    styled_lines
    |> Enum.take(inner_height)
    |> Enum.with_index()
    |> Enum.map(fn {%{text: text, style: style}, idx} ->
      rect = %Rect{x: lower_area.x + 2, y: lower_area.y + 1 + idx, width: rect_width, height: 1}
      {%Widgets.Paragraph{text: text, style: style}, rect}
    end)
  end

  defp styled(text, color, modifiers) do
    %{text: text, style: %Style{fg: color, modifiers: modifiers}}
  end

  defp separator_text(max_width), do: String.duplicate("─", max(max_width - 2, 1))

  defp preview_line_color(line) do
    cond do
      String.starts_with?(line, "+") -> :green
      String.starts_with?(line, "-") -> :red
      String.starts_with?(line, "@@") -> :cyan
      true -> :light_black
    end
  end

  defp wrap_text("", _max), do: [""]
  defp wrap_text(text, max) when max <= 0, do: [text]

  defp wrap_text(text, max) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(max)
    |> Enum.map(&Enum.join/1)
  end

  defp confirm_block do
    %Widgets.Block{
      title: " Confirm ",
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: :yellow}
    }
  end

  defp stream_display_label(%{cancelling: true, label: label}), do: label <> "  [Ctrl-C again to cancel]"
  defp stream_display_label(%{label: label}), do: label

  defp build_gauge_widget(title, ratio) do
    percent = round(ratio * 100)

    %Widgets.Gauge{
      ratio: min(ratio, 1.0),
      label: "#{percent}% (#{percent}/100)",
      gauge_style: %Style{fg: :cyan},
      block: %Widgets.Block{
        title: " #{title} ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }
  end

  defp build_label_widget(label) do
    %Widgets.Paragraph{
      text: "  #{label}",
      style: %Style{fg: :white, modifiers: [:bold]},
      alignment: :left
    }
  end

  defp build_log_widgets([], log_area, _width, _offset) do
    empty = %Widgets.Paragraph{
      text: "  Waiting for output...",
      style: %Style{fg: :white},
      block: output_block()
    }

    [{empty, log_area}]
  end

  defp build_log_widgets(log_tail, log_area, width, offset) do
    inner_height = max(log_area.height - 2, 1)
    inner_width = max(width - 4, 20)

    visible_rows = build_visible_log_rows(log_tail, inner_height, inner_width, offset)

    line_widgets =
      visible_rows
      |> Enum.with_index()
      |> Enum.map(&build_log_line_widget(&1, log_area))

    [{output_block(), log_area} | line_widgets]
  end

  defp build_visible_log_rows(log_tail, inner_height, inner_width, offset) do
    wrapped =
      log_tail
      |> Enum.reverse()
      |> Enum.flat_map(fn {color, text} ->
        text
        |> wrap_text(inner_width)
        |> Enum.map(fn line -> {color, line} end)
      end)

    total = length(wrapped)
    max_offset = max(total - inner_height, 0)
    clamped = min(max(offset, 0), max_offset)
    drop_count = max(total - inner_height - clamped, 0)

    wrapped |> Enum.drop(drop_count) |> Enum.take(inner_height)
  end

  defp build_log_line_widget({{color, text}, idx}, log_area) do
    rect = %Rect{
      x: log_area.x + 1,
      y: log_area.y + 1 + idx,
      width: max(log_area.width - 2, 1),
      height: 1
    }

    paragraph = %Widgets.Paragraph{
      text: text,
      style: %Style{fg: color}
    }

    {paragraph, rect}
  end

  defp output_block do
    %Widgets.Block{
      title: " Output ",
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: :cyan}
    }
  end

  defp build_footer_widget(%{mode: {:confirm, _}}) do
    %Widgets.Paragraph{
      text: "  Press Y/N/C to respond",
      style: %Style{fg: :white, modifiers: [:dim]}
    }
  end

  defp build_footer_widget(%{cancelling: cancelling?}) do
    text =
      if cancelling? do
        "  Ctrl-C again to cancel"
      else
        "  ↑/↓ scroll · PgUp/PgDn · Home/End · Ctrl-C twice to cancel"
      end

    %Widgets.Paragraph{
      text: text,
      style: %Style{fg: :white, modifiers: [:dim]}
    }
  end

  defp draw_progress(terminal, width, height, title, label, ratio, total, current) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    gauge_height = 3
    label_height = 3

    [_top, content, _bottom] = Layout.split(area, :vertical, [
      {:min, 0},
      {:length, gauge_height + label_height + 2},
      {:min, 0}
    ])

    [_left, inner, _right] = Layout.split(content, :horizontal, [
      {:length, 4},
      {:min, 20},
      {:length, 4}
    ])

    [label_area, gauge_area] = Layout.split(inner, :vertical, [
      {:length, label_height},
      {:length, gauge_height}
    ])

    percent = round(ratio * 100)
    gauge_label = "#{percent}% (#{current}/#{total})"

    gauge = %Widgets.Gauge{
      ratio: min(ratio, 1.0),
      label: gauge_label,
      gauge_style: %Style{fg: :cyan},
      block: %Widgets.Block{
        title: " #{title} ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    label_widget = %Widgets.Paragraph{
      text: "  #{label}",
      style: %Style{fg: :white, modifiers: [:bold]},
      alignment: :left
    }

    ExRatatui.draw(terminal, [
      {label_widget, label_area},
      {gauge, gauge_area}
    ])
  end

  defp draw_error(terminal, width, height, title, label, {:error, error}) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    [_top, content, _bottom] = Layout.split(area, :vertical, [
      {:min, 0},
      {:length, 6},
      {:min, 0}
    ])

    [_left, inner, _right] = Layout.split(content, :horizontal, [
      {:length, 4},
      {:min, 20},
      {:length, 4}
    ])

    error_text = "#{label}: #{inspect(error)}"

    error_widget = %Widgets.Paragraph{
      text: error_text,
      style: %Style{fg: :red, modifiers: [:bold]},
      alignment: :center,
      block: %Widgets.Block{
        title: " #{title} - Error ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :red}
      }
    }

    ExRatatui.draw(terminal, [{error_widget, inner}])
  end
end
