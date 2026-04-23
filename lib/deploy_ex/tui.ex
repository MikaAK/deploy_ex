defmodule DeployEx.TUI do
  @moduledoc """
  Helpers for running `ExRatatui` TUI screens without letting background log
  output corrupt the rendered frame.

  Elixir's default console Logger handler writes straight to stdout/stderr,
  which scribbles over any TUI that owns the terminal (common offender: ExAws
  HTTP retry warnings printed while an ansible deploy is streaming into a
  log pane). `run/1` wraps `ExRatatui.run/1` so the `:default` handler is
  silenced for the lifetime of the TUI and restored on exit, even when the
  inner function raises.
  """

  def enabled? do
    DeployEx.Config.tui_enabled?() and tty_available?()
  end

  def setup_no_tui(opts) do
    if opts[:no_tui] do
      Application.put_env(:deploy_ex, :tui_enabled, false)
    end

    opts
  end

  @doc """
  Runs an `ExRatatui.run/1` callback with the default console logger silenced
  so log lines don't corrupt the rendered frame. The original handler level
  is restored after the callback returns (or raises).
  """
  def run(fun) when is_function(fun, 1) do
    with_silenced_console_logger(fn -> ExRatatui.run(fun) end)
  end

  defp with_silenced_console_logger(fun) do
    previous_level = default_handler_level()
    _ = set_default_handler_level(:none)

    try do
      fun.()
    after
      _ = set_default_handler_level(previous_level)
    end
  end

  defp default_handler_level do
    case :logger.get_handler_config(:default) do
      {:ok, %{level: level}} -> level
      _ -> :all
    end
  end

  defp set_default_handler_level(level) do
    :logger.update_handler_config(:default, :level, level)
  end

  defp tty_available? do
    not ci?() and stdin_tty?()
  end

  defp ci? do
    System.get_env("CI") in ["true", "1", "yes"]
  end

  defp stdin_tty? do
    case :io.columns() do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
