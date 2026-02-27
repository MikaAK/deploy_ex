defmodule DeployEx.TUI do
  def enabled? do
    DeployEx.Config.tui_enabled?()
  end

  def setup_no_tui(opts) do
    if opts[:no_tui] do
      Application.put_env(:deploy_ex, :tui_enabled, false)
    end

    opts
  end
end
