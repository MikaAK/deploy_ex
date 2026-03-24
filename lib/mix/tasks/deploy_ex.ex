defmodule Mix.Tasks.DeployEx do
  use Mix.Task

  @shortdoc "Interactive wizard for all deploy_ex commands"
  @moduledoc """
  Launches an interactive TUI wizard for browsing and running all deploy_ex commands.

  Use arrow keys to navigate categories, Enter to select, and `/` to search across
  all commands. The wizard will guide you through any required inputs before running
  the selected command.

  ## Example
  ```bash
  mix deploy_ex
  mix deploy_ex --no-tui
  ```

  ## Options
  - `--no-tui` - Disable interactive TUI and use console prompts instead
  """

  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: [no_tui: :boolean])
    DeployEx.TUI.setup_no_tui(opts)
    DeployEx.TUI.Wizard.run(opts)
  end
end
