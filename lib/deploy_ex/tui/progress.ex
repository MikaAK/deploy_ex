defmodule DeployEx.TUI.Progress do
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

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

    {result, completed_steps} = ExRatatui.run(fn terminal ->
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

      {:tui_progress_done, result} ->
        Mix.shell().info([:green, "  ✓ #{title} complete"])
        result
    end
  end

  defp run_stream_tui(title, work_fn, opts) do
    caller = self()

    ExRatatui.run(fn terminal ->
      {width, height} = ExRatatui.terminal_size()

      state = %{
        ratio: 0.0,
        label: "Starting...",
        status: :running,
        result: nil,
        cancelling: false
      }

      worker = spawn_link(fn ->
        result = work_fn.(caller)
        send(caller, {:tui_progress_done, result})
      end)

      stream_loop(terminal, width, height, title, state, worker, opts)
    end)
  end

  def update_progress(tui_pid, ratio, label) do
    send(tui_pid, {:tui_progress_update, ratio, label})
  end

  defp stream_loop(terminal, width, height, title, state, worker, opts) do
    display_label = if state.cancelling, do: state.label <> "  [Ctrl-C again to cancel]", else: state.label
    draw_progress(terminal, width, height, title, display_label, state.ratio, 100, round(state.ratio * 100))

    case ExRatatui.poll_event(50) do
      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        stream_loop(terminal, new_width, new_height, title, state, worker, opts)

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} when not state.cancelling ->
        stream_loop(terminal, width, height, title, %{state | cancelling: true}, worker, opts)

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} when state.cancelling ->
        Process.exit(worker, :kill)
        {:error, :cancelled}

      _ ->
        receive do
          {:tui_progress_update, ratio, label} ->
            new_state = %{state | ratio: ratio, label: label}
            stream_loop(terminal, width, height, title, new_state, worker, opts)

          {:tui_progress_done, result} ->
            draw_progress(terminal, width, height, title, "Complete!", 1.0, 100, 100)
            Process.sleep(500)
            result
        after
          0 ->
            stream_loop(terminal, width, height, title, state, worker, opts)
        end
    end
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
