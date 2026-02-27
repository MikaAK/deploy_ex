defmodule DeployEx.TUI.Dashboard do
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets

  @spec run(String.t(), (-> term()), (term(), non_neg_integer(), non_neg_integer() -> list({ExRatatui.widget(), Rect.t()})), keyword()) :: :ok
  def run(title, fetch_fn, render_fn, opts \\ []) do
    if DeployEx.TUI.enabled?() do
      run_tui(title, fetch_fn, render_fn, opts)
    else
      run_console(title, fetch_fn, opts)
    end
  end

  defp run_console(title, fetch_fn, opts) do
    refresh_interval = Keyword.get(opts, :refresh_interval, 5000)
    console_fn = Keyword.get(opts, :console_render_fn)

    Mix.shell().info([:cyan, title])
    Mix.shell().info([:faint, "Refreshing every #{div(refresh_interval, 1000)}s... Press Ctrl+C to stop\n"])

    Stream.interval(refresh_interval)
      |> Stream.each(fn _ ->
        IO.write(IO.ANSI.clear())
        IO.write(IO.ANSI.home())

        data = fetch_fn.()

        if is_function(console_fn) do
          console_fn.(data)
        else
          Mix.shell().info(inspect(data, pretty: true))
        end

        Mix.shell().info([:faint, "\nRefreshing every #{div(refresh_interval, 1000)}s... Press Ctrl+C to stop"])
      end)
      |> Stream.run()
  end

  defp run_tui(title, fetch_fn, render_fn, opts) do
    refresh_interval = Keyword.get(opts, :refresh_interval, 5000)

    ExRatatui.run(fn terminal ->
      {width, height} = ExRatatui.terminal_size()

      state = %{
        data: nil,
        last_fetch: 0,
        refresh_interval: refresh_interval,
        title: title
      }

      dashboard_loop(terminal, width, height, state, fetch_fn, render_fn)
    end)
  end

  defp dashboard_loop(terminal, width, height, state, fetch_fn, render_fn) do
    now = System.monotonic_time(:millisecond)
    should_fetch = is_nil(state.data) or (now - state.last_fetch) >= state.refresh_interval

    state = if should_fetch do
      data = fetch_fn.()
      %{state | data: data, last_fetch: now}
    else
      state
    end

    draw_dashboard(terminal, width, height, state, render_fn)

    case ExRatatui.poll_event(100) do
      %ExRatatui.Event.Key{code: "q", kind: "press"} ->
        :ok

      %ExRatatui.Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]} ->
        :ok

      %ExRatatui.Event.Key{code: "r", kind: "press"} ->
        refreshed = %{state | data: fetch_fn.(), last_fetch: System.monotonic_time(:millisecond)}
        dashboard_loop(terminal, width, height, refreshed, fetch_fn, render_fn)

      %ExRatatui.Event.Resize{width: new_width, height: new_height} ->
        dashboard_loop(terminal, new_width, new_height, state, fetch_fn, render_fn)

      _ ->
        dashboard_loop(terminal, width, height, state, fetch_fn, render_fn)
    end
  end

  defp draw_dashboard(terminal, width, height, state, render_fn) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    [header_area, content_area, footer_area] = Layout.split(area, :vertical, [
      {:length, 1},
      {:min, 3},
      {:length, 1}
    ])

    header = %Widgets.Paragraph{
      text: " #{state.title}",
      style: %Style{fg: :cyan, modifiers: [:bold]}
    }

    footer = %Widgets.Paragraph{
      text: " q=quit  r=refresh  Auto-refresh: #{div(state.refresh_interval, 1000)}s",
      style: %Style{fg: :white, modifiers: [:dim]}
    }

    content_widgets = if is_nil(state.data) do
      loading = %Widgets.Paragraph{
        text: "Loading...",
        style: %Style{fg: :yellow},
        alignment: :center
      }

      [{loading, content_area}]
    else
      render_fn.(state.data, content_area.width, content_area.height)
    end

    base_widgets = [{header, header_area}, {footer, footer_area}]

    adjusted_content_widgets = Enum.map(content_widgets, fn {widget, rect} ->
      adjusted_rect = %Rect{
        x: rect.x + content_area.x,
        y: rect.y + content_area.y,
        width: min(rect.width, content_area.width),
        height: min(rect.height, content_area.height)
      }

      {widget, adjusted_rect}
    end)

    ExRatatui.draw(terminal, base_widgets ++ adjusted_content_widgets)
  end
end
