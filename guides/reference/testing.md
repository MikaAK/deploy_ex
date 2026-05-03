# Testing Guide

## Running Tests

```bash
mix test                                                    # all tests
mix test test/deploy_ex/project_context_test.exs            # specific file
mix test test/deploy_ex/project_context_test.exs:42         # specific line
```

## Test Structure

```
test/
  test_helper.exs
  deploy_ex_test.exs
  deploy_ex/
    aws_infrastructure_test.exs                # AWS XML response parsing
    change_planner_test.exs                    # rename/split/merge classification
    diff_test.exs                              # unified diff parsing + apply
    git_operations_test.exs                    # QA branch resolution + commit/push
    github_actions_test.exs                    # workflow glob match + run polling
    grafana_test.exs                           # dashboard install logic
    k6_runner_test.exs                         # k6 EC2 lifecycle
    llm_merge_test.exs                         # LLM merge + proposal review
    priv_manifest_test.exs                     # SHA256 manifest tracking
    priv_renderer_test.exs                     # EEx render to temp dir
    priv_upgrade_integration_test.exs          # full upgrade pipeline
    project_context_test.exs                   # umbrella vs single-app detection
    qa_node_test.exs                           # QA EC2 lifecycle + S3 state
    qa_playbook_test.exs                       # per-node playbook gen
    release_lookup_test.exs                    # release picker + git filtering
    tool_installer_test.exs                    # platform detection
    upgrade_orchestrator_test.exs              # upgrade_priv command coordination
    release_uploader/
      redeploy_config_test.exs
      state_test.exs
      update_validator_test.exs
      update_validator/
        mix_deps_tree_parser_test.exs
        mix_lock_file_diff_parser_test.exs
  mix/
    tasks/
      ansible_deploy_test.exs
      deploy_ex_qa_create_test.exs
      deploy_ex_qa_deploy_test.exs
      deploy_ex_qa_destroy_test.exs
  support/
    fake_apps/                                  # cfx_web, lib_thing, no_module, worker_app
    fixtures/
      workflows/                                # ambiguous, happy, no_deploy
```

## Test Conventions

- Use `ExUnit.Case` with `async: true` where possible.
- **No mocking libraries** — use dependency injection.
- `refute` over `assert !` or `assert not`.
- Never `Application.put_env/3` in tests — pass deps in via parameter.

### Dependency Injection Pattern

Modules accept an optional injection point for their external dependency. From `ProjectContext`:

```elixir
def type(mix_project \\ Mix.Project) do
  if mix_project.umbrella?(), do: :umbrella, else: :single_app
end
```

Tests pass fakes:

```elixir
defmodule FakeUmbrellaMixProject do
  def umbrella?, do: true
  def get, do: __MODULE__
  def project, do: [apps_path: "test/support/fake_apps", releases: [...]]
  def apps_paths, do: %{cfx_web: "test/support/fake_apps/cfx_web"}
end

assert ProjectContext.type(FakeUmbrellaMixProject) === :umbrella
```

The `test/support/fake_apps/` tree contains four real-feeling Elixir apps (`cfx_web`, `lib_thing`, `no_module`, `worker_app`) so `ProjectContext`, `ReleaseUploader`, and the priv tests have something concrete to introspect.

## Workflow Fixtures

`test/support/fixtures/workflows/` holds three sample `.github/workflows/` trees consumed by `GitHubActionsTest`:

| Fixture | What it covers |
|---------|----------------|
| `happy/` | A clear winner — one workflow that runs `mix deploy_ex.release` on the QA branch |
| `ambiguous/` | Multiple workflows match — drives the disambiguation path |
| `no_deploy/` | No workflow runs `deploy_ex.release` — the not-found error path |

## What's Tested

| Area | Key assertions |
|------|----------------|
| `ProjectContext` | umbrella vs single-app, app discovery, release synthesis, path resolution |
| `UpdateValidator` | code change, dep change, lock file diff, whitelist/blacklist filtering |
| `RedeployConfig` | whitelist/blacklist regex matching |
| `PrivManifest` | sha256 hashing, manifest read/write, file tracking |
| `PrivRenderer` | EEx render with project vars, temp dir cleanup |
| `ChangePlanner` | rename/split/merge classification thresholds |
| `Diff` | unified diff parse, hunk accept/reject |
| `LLMMerge` | proposal review, autonomous merge |
| `priv_upgrade_integration_test` | end-to-end upgrade pipeline |
| `GitOperations` | QA branch resolve (reuse vs. new), commit + push, revert + push |
| `GitHubActions` | branch glob match, build workflow detection, sub-workflow resolution, run polling |
| `QaNode` | create/terminate, S3 state, LB attach/detach, interactive picker |
| `QaPlaybook` | playbook YAML generation, sentinel placeholder substitution |
| `ToolInstaller` | platform detection, install command building |
| `ReleaseLookup` | git filter best-effort fallback, release type filtering |
| `K6Runner` | EC2 lifecycle, S3 state |
| `AWS XML parsing` | subnet, key pair, VPC response shapes |
| `Mix tasks (ansible.deploy, qa.create/deploy/destroy)` | argument parsing + pipeline orchestration |

See also: [Code Standards](../explanation/code_standards.md)
