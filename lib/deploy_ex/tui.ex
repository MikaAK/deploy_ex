defmodule DeployEx.TUI do
  def enabled? do
    DeployEx.Config.tui_enabled?() and tty_available?()
  end

  def setup_no_tui(opts) do
    if opts[:no_tui] do
      Application.put_env(:deploy_ex, :tui_enabled, false)
    end

    opts
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
