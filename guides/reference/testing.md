# Testing Guide

## Running Tests

```bash
mix test                                    # all tests
mix test test/deploy_ex/project_context_test.exs  # specific file
mix test test/deploy_ex/project_context_test.exs:42  # specific line
```

Known: 8 pre-existing failures in `aws_infrastructure_test.exs` (XML parsing tests).

## Test Structure

```
test/
  test_helper.exs
  deploy_ex_test.exs                              # basic doctests
  deploy_ex/
    aws_infrastructure_test.exs                    # AWS XML response parsing
    grafana_test.exs
    k6_runner_test.exs
    priv_manifest_test.exs                         # manifest SHA256 tracking
    qa_node_test.exs
    project_context_test.exs                       # umbrella/single-app detection
    release_uploader/
      redeploy_config_test.exs                     # whitelist/blacklist filtering
      update_validator_test.exs                    # change detection logic
      update_validator/
        mix_deps_tree_parser_test.exs              # deps.tree output parsing
        mix_lock_file_diff_parser_test.exs         # mix.lock diff parsing
```

## Test Conventions

- Use `ExUnit.Case` with `async: true` where possible
- No mocking libraries — use dependency injection instead
- `refute` over `assert !` or `assert not`
- Never use `Application.put_env/3` in tests

### Dependency Injection for Testing

Modules that need testability accept an optional parameter for their external dependency. Example from `ProjectContext`:

```elixir
def type(mix_project \\ Mix.Project) do
  if mix_project.umbrella?(), do: :umbrella, else: :single_app
end
```

Tests pass fake modules:

```elixir
defmodule FakeUmbrellaMixProject do
  def umbrella?, do: true
  def get, do: __MODULE__
  def project, do: [apps_path: "test/support/fake_apps", releases: [...]]
  def apps_paths, do: %{app_a: "test/support/fake_apps/app_a"}
end

test "returns :umbrella for umbrella projects" do
  assert ProjectContext.type(FakeUmbrellaMixProject) === :umbrella
end
```

## Fixtures

Parser tests use fixture files in `test/deploy_ex/release_uploader/update_validator/`:

| File | Used By | Content |
|------|---------|---------|
| `mix_deps_tree.txt` | `MixDepsTreeParserTest` | Sample `mix deps.tree` output |
| `mix_lock_file_diff.txt` | `MixLockFileDiffParserTest` | Sample `git diff` of mix.lock |

## What's Tested

| Area | Key Assertions |
|------|---------------|
| ProjectContext | Umbrella/single-app detection, app discovery, release synthesis, path resolution |
| UpdateValidator | Code change detection, dependency change detection, whitelist/blacklist filtering |
| RedeployConfig | Whitelist pattern matching, blacklist pattern matching |
| PrivManifest | SHA256 hashing, manifest read/write, file tracking |
| AWS parsing | Subnet, key pair, VPC XML response parsing |

See also: [Code Standards](code_standards.md)
