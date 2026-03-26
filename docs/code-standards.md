# Code Standards

## Error Handling

All context functions return `{:ok, result}` or `{:error, %ErrorMessage{}}`. Chain fallible operations with `with`:

```elixir
with :ok <- DeployExHelpers.check_valid_project(),
     {:ok, releases} <- DeployExHelpers.fetch_mix_releases(),
     {:ok, remote} <- ReleaseUploader.fetch_all_remote_releases(opts) do
  # success path
else
  {:error, e} -> Mix.raise(to_string(e))
end
```

ErrorMessage structs map to HTTP status codes: `not_found`, `bad_request`, `failed_dependency`, etc.

For aggregating multiple async results, use `DeployEx.Utils.reduce_task_status_tuples/1`.

## Configuration

All config access goes through `DeployEx.Config`. Never call `Application.get_env(:deploy_ex, ...)` directly — the Config module handles defaults and derivation logic.

```elixir
# Correct
Config.aws_region()
Config.aws_release_bucket()

# Wrong
Application.get_env(:deploy_ex, :aws_region)
```

## Shell Commands

Always execute shell commands through `DeployEx.Utils`:

| Function | Use For |
|----------|---------|
| `run_command/3` | Fire-and-forget with status |
| `run_command_with_return/3` | Capture output |
| `run_command_streaming/4` | Stream output with callbacks |
| `run_command_with_input/3` | Interactive commands |

Never use `System.cmd/3` or `System.shell/2` directly from Mix tasks.

## AWS Patterns

All ExAws calls must include explicit region:

```elixir
ExAws.EC2.describe_instances(filters: filters)
|> ExAws.request(region: opts[:aws_region] || Config.aws_region())
```

Tag all resources with: `Group`, `Environment`, `ManagedBy` (value: `"DeployEx"`).

Resource discovery uses tag-based filtering — find instances by `InstanceGroup` tag, not by name.

## Template Pattern

Templates live in `priv/` and are resolved via `DeployExHelpers.priv_folder/1`, which checks `./deploys/` first (user customizations) then falls back to the deploy_ex priv directory.

Render with `DeployExHelpers.write_template/4`:
```elixir
DeployExHelpers.write_template(template_path, output_path, variables, opts)
```

## Naming Conventions

| Helper | Example | Used For |
|--------|---------|----------|
| `project_name()` | `"MyApp"` | Module-derived, AWS tags |
| `underscored_project_name()` | `"my_app"` | Ansible, file names |
| `kebab_project_name()` | `"my-app"` | Terraform, AWS resources |
| `title_case_project_name()` | `"My App"` | Display names |

## TUI Pattern

Check `DeployEx.TUI.enabled?/0` before rendering — it returns false in CI environments or when stdin is not a TTY. Support `--no-tui` flag via `DeployEx.TUI.setup_no_tui/1`.

ExRatatui widgets use event loop pattern with `q`/`Ctrl+C` to quit, with console-mode fallback.

## Code Style

- `===`/`!==` over `==`/`!=`
- `is_nil/1` over `== nil`
- `Enum.empty?/1` over `length(list) === 0`
- Pipe chains: start with value, minimum 2 operations
- Short case clauses on one line: `:atom -> expression`
- No `()` on zero-arity pipe calls: `|> Map.new` not `|> Map.new()`
- Logger: `Logger.info("#{__MODULE__}: message, value: #{inspect(value)}")`
- Section large modules with `# SECTION NAME` comment headers

## Testing

- ExUnit with `async: true` where possible
- No mocking libraries — use dependency injection (e.g. `ProjectContext` accepts `mix_project` param)
- Fixture files for parser tests in `test/deploy_ex/release_uploader/update_validator/`
- `refute` over `assert !` or `assert not`
- Never `Application.put_env/3` in tests

See also: [Testing Guide](testing-guide.md) | [System Architecture](system-architecture.md)
