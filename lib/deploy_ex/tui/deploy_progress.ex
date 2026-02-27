defmodule DeployEx.TUI.DeployProgress do
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

  @ansible_task_regex ~r/^TASK \[(.+)\]/
  @ansible_play_recap_regex ~r/^PLAY RECAP/

  def run(app_playbooks, run_fn, opts \\ []) do
    if DeployEx.TUI.enabled?() do
      run_tui(app_playbooks, run_fn, opts)
    else
      run_console(app_playbooks, run_fn, opts)
    end
  end

  defp run_console(app_playbooks, run_fn, opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)
    timeout = Keyword.get(opts, :timeout, :timer.minutes(30))

    app_playbooks
      |> Task.async_stream(fn playbook ->
        run_fn.(playbook, fn line -> IO.puts(line) end)
      end, max_concurrency: max_concurrency, timeout: timeout)
      |> DeployEx.Utils.reduce_status_tuples()
  end

  defp run_tui(app_playbooks, run_fn, opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)
    timeout = Keyword.get(opts, :timeout, :timer.minutes(30))
    coordinator = self()

    app_names = Enum.map(app_playbooks, &extract_app_name/1)

    initial_states = Map.new(app_names, fn name ->
      {name, %{status: :pending, current_task: "Waiting...", tasks_completed: 0, error: nil, output_tail: []}}
    end)

    ExRatatui.run(fn terminal ->
      {width, height} = ExRatatui.terminal_size()

      task = Task.async(fn ->
        app_playbooks
          |> Task.async_stream(fn playbook ->
            app_name = extract_app_name(playbook)

            callback = fn line ->
              send(coordinator, {:deploy_output_line, app_name, line})

              case parse_ansible_line(line) do
                {:task, task_name} ->
                  send(coordinator, {:deploy_task_update, app_name, task_name})
                :recap ->
                  send(coordinator, {:deploy_complete, app_name})
                :ignore ->
                  :ok
              end
            end

            send(coordinator, {:deploy_started, app_name})
            result = run_fn.(playbook, callback)

            send(coordinator, {:deploy_finished, app_name, result})
            result
          end, max_concurrency: max_concurrency, timeout: timeout)
          |> DeployEx.Utils.reduce_status_tuples()
      end)

      deploy_loop(terminal, width, height, initial_states, task)
    end)
    |> print_logs_after_tui()
  end

  defp deploy_loop(terminal, width, height, states, task) do
    draw_deploy_status(terminal, width, height, states)

    case ExRatatui.poll_event(100) do
      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        deploy_loop(terminal, new_width, new_height, states, task)

      _ ->
        states = drain_messages(states)

        case Task.yield(task, 0) do
          {:ok, result} ->
            draw_deploy_status(terminal, width, height, states)
            Process.sleep(1000)
            {result, states}

          nil ->
            deploy_loop(terminal, width, height, states, task)
        end
    end
  end

  defp drain_messages(states) do
    receive do
      {:deploy_started, app_name} ->
        states
          |> Map.update!(app_name, &%{&1 | status: :running, current_task: "Starting..."})
          |> drain_messages()

      {:deploy_task_update, app_name, task_name} ->
        states
          |> Map.update!(app_name, &%{&1 |
            current_task: task_name,
            tasks_completed: &1.tasks_completed + 1
          })
          |> drain_messages()

      {:deploy_complete, app_name} ->
        states
          |> Map.update!(app_name, &%{&1 | status: :complete, current_task: "Complete"})
          |> drain_messages()

      {:deploy_finished, app_name, :ok} ->
        states
          |> Map.update!(app_name, &%{&1 | status: :complete, current_task: "Complete"})
          |> drain_messages()

      {:deploy_finished, app_name, {:ok, _}} ->
        states
          |> Map.update!(app_name, &%{&1 | status: :complete, current_task: "Complete"})
          |> drain_messages()

      {:deploy_finished, app_name, {:error, error}} ->
        states
          |> Map.update!(app_name, &%{&1 | status: :failed, current_task: "Failed", error: error})
          |> drain_messages()

      {:deploy_output_line, app_name, line} ->
        states
          |> Map.update!(app_name, fn state ->
            %{state | output_tail: state.output_tail ++ [line]}
          end)
          |> drain_messages()
    after
      0 -> states
    end
  end

  defp print_logs_after_tui({result, states}) when is_map(states) do
    sorted = Enum.sort_by(states, fn {name, _} -> name end)

    Enum.each(sorted, fn {name, state} ->
      header_color = if state.status === :failed, do: :red, else: :green
      status_label = if state.status === :failed, do: "FAILED", else: "OK"

      Mix.shell().info([
        header_color, "\n#{String.duplicate("=", 60)}",
        header_color, "\n#{name} [#{status_label}]",
        header_color, "\n#{String.duplicate("=", 60)}", :reset
      ])

      if state.error do
        Mix.shell().error("Error: #{format_error(state.error)}")
      end

      Enum.each(state.output_tail, fn line ->
        Mix.shell().info(line)
      end)
    end)

    result
  end

  defp print_logs_after_tui(result), do: result

  defp format_error(%ErrorMessage{} = error), do: ErrorMessage.to_string(error)
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp draw_deploy_status(terminal, width, height, states) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    [header_area, content_area, footer_area] = Layout.split(area, :vertical, [
      {:length, 1},
      {:min, 3},
      {:length, 1}
    ])

    completed = Enum.count(states, fn {_, state} -> state.status in [:complete, :failed] end)
    total = map_size(states)

    header = %Widgets.Paragraph{
      text: " Deploying Applications (#{completed}/#{total})",
      style: %Style{fg: :cyan, modifiers: [:bold]}
    }

    footer = %Widgets.Paragraph{
      text: " Waiting for all deployments to complete...",
      style: %Style{fg: :white, modifiers: [:dim]}
    }

    lines = states
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, state} ->
        {symbol, _color} = status_symbol(state.status)
        task_display = truncate_text(state.current_task, max(width - String.length(name) - 10, 20))
        "  #{symbol} #{name}  #{task_display}"
      end)

    text = Enum.join(lines, "\n")

    content = %Widgets.Paragraph{
      text: text,
      style: %Style{fg: :white},
      block: %Widgets.Block{
        title: " Deploy Status ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    ExRatatui.draw(terminal, [
      {header, header_area},
      {content, content_area},
      {footer, footer_area}
    ])
  end

  defp status_symbol(:pending), do: {"○", :faint}
  defp status_symbol(:running), do: {"▸", :cyan}
  defp status_symbol(:complete), do: {"✓", :green}
  defp status_symbol(:failed), do: {"✗", :red}

  defp truncate_text(text, max_len) when byte_size(text) > max_len do
    String.slice(text, 0, max_len - 3) <> "..."
  end

  defp truncate_text(text, _max_len), do: text

  def parse_ansible_line(line) do
    cond do
      Regex.match?(@ansible_task_regex, line) ->
        [_, task_name] = Regex.run(@ansible_task_regex, line)
        {:task, task_name}

      Regex.match?(@ansible_play_recap_regex, line) ->
        :recap

      true ->
        :ignore
    end
  end

  defp extract_app_name(playbook_path) do
    playbook_path
      |> Path.basename()
      |> String.replace(~r/\.[^\.]*$/, "")
  end
end
