---
name: deploy-ex-dev
description: "Use when writing code inside the deploy_ex library itself — adding new Mix tasks, modifying existing tasks, extending AWS modules, working with the template pipeline (priv/ EEx templates), writing tests, or understanding deploy_ex internals. Triggers on: adding a task, new mix task, extend deploy_ex, template pipeline, priv templates, deploy_ex module, writing tests for deploy_ex, how does deploy_ex work internally. Always use this skill when modifying any file in lib/deploy_ex/, lib/mix/tasks/, priv/, or test/ within the deploy_ex repository."
---

# deploy_ex Development

Guide for contributing to the deploy_ex codebase — adding features, extending modules, writing tests.

## Project Structure

```
lib/
  deploy_ex/              # Core modules (AWS, release, TUI, config)
    release_uploader/     # Release management subsystem
    tui/                  # Terminal UI components (ExRatatui)
  mix/
    tasks/                # 73 Mix tasks (the CLI interface)
    deploy_ex_helpers.ex  # Shared helpers all tasks use
priv/
  terraform/              # Terraform EEx templates + modules
  ansible/                # Ansible EEx templates + roles (21 roles)
test/
  deploy_ex/              # Unit tests
```

## Adding a New Mix Task

Every task follows this pattern:

```elixir
defmodule Mix.Tasks.DeployEx.MyTask do
  use Mix.Task

  alias DeployEx.Config

  @shortdoc "One-line description"
  @moduledoc """
  Detailed description.

  ## Options
  - `option_name` - Description
  """

  def run(args) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:telemetry)

    opts = args
      |> parse_args
      |> Keyword.put_new(:some_default, Config.some_value())

    with :ok <- DeployExHelpers.check_valid_project(),
         {:ok, releases} <- DeployExHelpers.fetch_mix_releases() do
      # task logic
    else
      {:error, e} -> Mix.raise(to_string(e))
    end
  end

  defp parse_args(args) do
    {opts, _} = OptionParser.parse!(args,
      aliases: [f: :force, q: :quiet],
      switches: [force: :boolean, quiet: :boolean]
    )
    opts
  end
end
```

Key patterns:
- Start with `:hackney` and `:telemetry` if making AWS calls
- Call `check_valid_project()` as the first `with` clause
- Use `with` chains for error handling, not nested `case`
- Parse args with `OptionParser.parse!/2`
- Add the task to `TUI.Wizard.CommandRegistry` if it should appear in the wizard

After creating a task, also register it in `lib/deploy_ex/tui/wizard/command_registry.ex` under the appropriate category.

## Code Standards (critical — read before writing code)

### Error Handling
Return `{:ok, result}` or `{:error, %ErrorMessage{}}` from all functions. Use ErrorMessage constructors: `not_found`, `bad_request`, `failed_dependency`.

### Shell Commands
Execute through `DeployEx.Utils` — never `System.cmd` or `System.shell` directly:
- `Utils.run_command/3` — fire-and-forget
- `Utils.run_command_with_return/3` — capture output
- `Utils.run_command_streaming/4` — stream with callbacks
- `Utils.run_command_with_input/3` — interactive

### Configuration
Access via `DeployEx.Config` — never `Application.get_env(:deploy_ex, ...)` directly.

### AWS Calls
Include explicit region on every ExAws request:
```elixir
ExAws.EC2.describe_instances(filters: filters)
|> ExAws.request(region: opts[:aws_region] || Config.aws_region())
```

Tag all resources: `Group`, `Environment`, `ManagedBy` (value: `"DeployEx"`).

### Code Style
- `===`/`!==` over `==`/`!=`; `is_nil/1` over `== nil`
- Pipe chains: start with value, minimum 2 ops, no `()` on zero-arity calls
- Short case clauses on one line: `:atom -> expression`
- Logger: `Logger.info("#{__MODULE__}: message, value: #{inspect(value)}")`
- Section large modules with `# SECTION NAME` headers

## Template Pipeline

Templates live in `priv/{terraform,ansible}/` as `.eex` files. They're rendered by `DeployExHelpers.write_template/4`:

```elixir
DeployExHelpers.write_template(template_path, output_path, variables, opts)
```

Template resolution via `DeployExHelpers.priv_folder/1` checks `./deploys/` first (user customizations), then falls back to deploy_ex's priv directory.

The manifest (`.deploy_ex_manifest.exs`) tracks SHA256 hashes for intelligent upgrades via `DeployEx.PrivManifest`.

### Adding a New Template

1. Create `.eex` file in `priv/{terraform,ansible}/`
2. Add rendering logic in the relevant `mix *.build` task
3. Pass template variables as a map to `write_template/4`
4. Register in `PrivManifest` if it should be tracked for upgrades

## Writing Tests

Tests use ExUnit with `async: true`. No mocking libraries — use dependency injection:

```elixir
# Module accepts injectable dependency
def type(mix_project \\ Mix.Project) do
  if mix_project.umbrella?(), do: :umbrella, else: :single_app
end

# Test passes a fake
defmodule FakeUmbrellaMixProject do
  def umbrella?, do: true
  def get, do: __MODULE__
  def project, do: [apps_path: "test/support/fake_apps"]
end

test "returns :umbrella for umbrella projects" do
  assert ProjectContext.type(FakeUmbrellaMixProject) === :umbrella
end
```

Parser tests use fixture files in `test/deploy_ex/release_uploader/update_validator/`.

Use `refute` over `assert !`. Never `Application.put_env/3` in tests.

## Key Module Map

| Module | Purpose | When to Touch |
|--------|---------|---------------|
| `DeployExHelpers` | Shared task helpers (project introspection, SSH, file I/O) | Adding common functionality for tasks |
| `DeployEx.Config` | Runtime config with defaults | Adding new config keys |
| `DeployEx.ProjectContext` | Umbrella vs single-app detection | Changing project type logic |
| `DeployEx.Utils` | Shell execution, error aggregation | Adding shell command patterns |
| `DeployEx.ReleaseUploader` | Release coordination | Changing release build/upload flow |
| `DeployEx.ReleaseUploader.UpdateValidator` | Change detection (git diff, deps) | Modifying when rebuilds trigger |
| `DeployEx.Terraform` | Terraform CLI wrapper | Adding terraform commands |
| `DeployEx.SSH` | SSH connections and tunneling | Remote execution features |
| `DeployEx.QaNode` | QA instance lifecycle | QA features |
| `DeployEx.K6Runner` | Load testing runners | Load test features |
| `DeployEx.TUI.*` | Terminal UI | Interactive features |

For architecture diagrams and data flows, read `docs/system-architecture.md`.
For full module inventory, read `docs/codebase-summary.md`.
