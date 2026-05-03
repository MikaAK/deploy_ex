# `qa.create --wait-for-build` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--wait-for-build` flag to `mix deploy_ex.qa.create` that commits/pushes the SSL+host rewrites, waits for the GitHub Actions workflow that runs `mix deploy_ex.release` to complete, then deploys the freshly-built artifact.

**Architecture:** Two new modules — `DeployEx.GitHubActions` (workflow YAML parsing + `gh` CLI polling) and `DeployEx.GitOperations` (qa branch resolution, commit/push, revert). `DeployEx.ToolInstaller` extended to install `gh` on platforms it already supports. Pipeline in `qa.create.ex` gains 5 new steps (12 → 18) when the flag is on. Failure routes to a 4-option recovery prompt via the existing `Progress.confirm/2` infrastructure.

**Tech Stack:** Elixir 1.18, `yaml_elixir` (new dep), GitHub CLI (`gh`), git, ratatui-based TUI.

**Spec:** `docs/superpowers/specs/2026-05-03-qa-create-wait-for-build-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `mix.exs` | Modify | Add `yaml_elixir` dep |
| `lib/deploy_ex/github_actions.ex` | Create | Workflow detection, gh polling, run discovery |
| `lib/deploy_ex/git_operations.ex` | Create | QA branch resolution, commit/push, revert |
| `lib/deploy_ex/tool_installer.ex` | Modify | Add `:gh` install support |
| `lib/mix/tasks/deploy_ex.qa.create.ex` | Modify | New flags, new pipeline steps, failure prompt |
| `lib/deploy_ex/tui/progress.ex` | Modify | (only if needed) Multi-option confirm support |
| `test/deploy_ex/github_actions_test.exs` | Create | GitHubActions unit tests |
| `test/deploy_ex/git_operations_test.exs` | Create | GitOperations unit tests |
| `test/deploy_ex/tool_installer_test.exs` | Modify | Add `:gh` test cases |
| `test/mix/tasks/deploy_ex_qa_create_test.exs` | Modify | New flag parsing + integration |
| `test/support/fixtures/workflows/cfx_pipeline.yml` | Create | Fixture: top-level pipeline workflow |
| `test/support/fixtures/workflows/deploy.yml` | Create | Fixture: sub-workflow with `mix deploy_ex.release` |
| `test/support/fixtures/workflows/no_deploy.yml` | Create | Fixture: no `deploy_ex.release` (negative case) |
| `test/support/fixtures/workflows/ambiguous_a.yml` | Create | Fixture: ambiguous match A |
| `test/support/fixtures/workflows/ambiguous_b.yml` | Create | Fixture: ambiguous match B |

---

## Task 1: Add `yaml_elixir` dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add `yaml_elixir` to deps**

In `mix.exs`, add to the `deps/0` list (alphabetical order matters where the file is alphabetized):

```elixir
{:yaml_elixir, "~> 2.11"},
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: `yaml_elixir` and its transitive `yamerl` are downloaded; no errors.

- [ ] **Step 3: Sanity-compile**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "feat(deps): add yaml_elixir for workflow parsing"
```

---

## Task 2: Workflow fixtures

**Files:**
- Create: `test/support/fixtures/workflows/cfx_pipeline.yml`
- Create: `test/support/fixtures/workflows/deploy.yml`
- Create: `test/support/fixtures/workflows/no_deploy.yml`
- Create: `test/support/fixtures/workflows/ambiguous_a.yml`
- Create: `test/support/fixtures/workflows/ambiguous_b.yml`

- [ ] **Step 1: Create the fixtures directory**

```bash
mkdir -p test/support/fixtures/workflows
```

- [ ] **Step 2: Write `cfx_pipeline.yml`** (sanitized copy of cfx umbrella's pipeline)

```yaml
name: Pipeline
on:
  push:
    branches:
      - main
      - 'qa-**'
      - 'qa/**'
jobs:
  mix-compile-prod:
    name: Compile (prod)
    uses: ./.github/workflows/mix-compile-prod.yml
  coverage:
    name: Coverage
    uses: ./.github/workflows/coverage.yml
    needs:
      - mix-compile-prod
  deploy-qa:
    name: Deploy (QA)
    if: ${{ !failure() && !cancelled() && github.event_name == 'push' && (startsWith(github.ref, 'refs/heads/qa-') || startsWith(github.ref, 'refs/heads/qa/')) }}
    uses: ./.github/workflows/deploy.yml
    needs:
      - mix-compile-prod
      - coverage
```

- [ ] **Step 3: Write `deploy.yml`** (sub-workflow that actually runs `deploy_ex.release`)

```yaml
name: deploy
on:
  workflow_call:
jobs:
  deploy:
    name: Build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build release
        run: mix deploy_ex.release
      - name: Upload release
        run: mix deploy_ex.upload
```

- [ ] **Step 4: Write `no_deploy.yml`** (negative case: no deploy_ex.release)

```yaml
name: docs
on:
  push:
    branches:
      - 'qa-**'
jobs:
  build-docs:
    runs-on: ubuntu-latest
    steps:
      - run: echo "build docs"
      - run: echo "no release built here"
```

- [ ] **Step 5: Write `ambiguous_a.yml` and `ambiguous_b.yml`** (both match)

`ambiguous_a.yml`:
```yaml
name: build-a
on:
  push:
    branches:
      - 'qa/**'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: mix deploy_ex.release
```

`ambiguous_b.yml`:
```yaml
name: build-b
on:
  push:
    branches:
      - 'qa/**'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: mix deploy_ex.release
```

- [ ] **Step 6: Commit**

```bash
git add test/support/fixtures/workflows
git commit -m "test(fixtures): add github workflow fixtures for build detection"
```

---

## Task 3: `GitHubActions.find_build_workflow/2` — branch glob matching

**Files:**
- Create: `lib/deploy_ex/github_actions.ex`
- Create: `test/deploy_ex/github_actions_test.exs`

The detection logic has two parts: (a) which workflows trigger on the qa branch, (b) of those, which has a job that runs `mix deploy_ex.release`. Task 3 covers the first half. Task 4 adds the second.

- [ ] **Step 1: Write the failing test for branch matching**

In `test/deploy_ex/github_actions_test.exs`:

```elixir
defmodule DeployEx.GitHubActionsTest do
  use ExUnit.Case, async: true

  alias DeployEx.GitHubActions

  @fixtures_root Path.expand("../support/fixtures/workflows", __DIR__)

  describe "branch_glob_match?/2" do
    test "matches qa/cfx_web-canary against qa/**" do
      assert GitHubActions.branch_glob_match?("qa/**", "qa/cfx_web-canary")
    end

    test "matches qa-experimental against qa-**" do
      assert GitHubActions.branch_glob_match?("qa-**", "qa-experimental")
    end

    test "matches main against main" do
      assert GitHubActions.branch_glob_match?("main", "main")
    end

    test "does not match qa/foo against main" do
      refute GitHubActions.branch_glob_match?("main", "qa/foo")
    end

    test "does not match qa-foo against qa/**" do
      refute GitHubActions.branch_glob_match?("qa/**", "qa-foo")
    end
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `mix test test/deploy_ex/github_actions_test.exs`
Expected: FAIL — `DeployEx.GitHubActions` is not defined.

- [ ] **Step 3: Implement minimal module + `branch_glob_match?/2`**

In `lib/deploy_ex/github_actions.ex`:

```elixir
defmodule DeployEx.GitHubActions do
  @moduledoc """
  GitHub Actions integration: workflow detection (parses .github/workflows/*.yml
  to find the workflow that runs `mix deploy_ex.release` for a given branch),
  and `gh` CLI wrappers for run discovery + status polling.
  """

  @doc """
  Checks whether a GitHub Actions branch trigger glob (e.g. `qa/**`) matches a
  concrete branch name (e.g. `qa/cfx_web-canary`).

  GH supports `*` (matches any chars except `/`) and `**` (matches any chars
  including `/`). We translate to a regex.
  """
  @spec branch_glob_match?(String.t(), String.t()) :: boolean()
  def branch_glob_match?(pattern, branch) do
    regex_source =
      pattern
      |> String.split("**", parts: :infinity)
      |> Enum.map(&escape_segment/1)
      |> Enum.join(".*")

    Regex.match?(~r/^#{regex_source}$/, branch)
  end

  defp escape_segment(segment) do
    segment
    |> Regex.escape()
    |> String.replace("\\*", "[^/]*")
  end
end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `mix test test/deploy_ex/github_actions_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/github_actions.ex test/deploy_ex/github_actions_test.exs
git commit -m "feat(github_actions): add branch_glob_match? for workflow trigger matching"
```

---

## Task 4: `GitHubActions.find_build_workflow/2` — full implementation

**Files:**
- Modify: `lib/deploy_ex/github_actions.ex`
- Modify: `test/deploy_ex/github_actions_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/deploy_ex/github_actions_test.exs`:

```elixir
  describe "find_build_workflow/2" do
    test "picks pipeline.yml when its sub-workflow runs deploy_ex.release for the qa branch" do
      result = GitHubActions.find_build_workflow(@fixtures_root, "qa/cfx_web-canary")
      assert {:ok, %{file: "cfx_pipeline.yml", job_id: "deploy-qa"}} = result
    end

    test "returns :ambiguous when 2+ workflows match" do
      ambiguous_root = Path.expand("../support/fixtures/workflows_ambiguous", __DIR__)
      File.mkdir_p!(ambiguous_root)
      File.cp!(Path.join(@fixtures_root, "ambiguous_a.yml"), Path.join(ambiguous_root, "ambiguous_a.yml"))
      File.cp!(Path.join(@fixtures_root, "ambiguous_b.yml"), Path.join(ambiguous_root, "ambiguous_b.yml"))

      result = GitHubActions.find_build_workflow(ambiguous_root, "qa/foo")
      assert {:error, %ErrorMessage{code: :conflict}} = result

      File.rm_rf!(ambiguous_root)
    end

    test "returns :not_found when no workflow runs deploy_ex.release" do
      no_deploy_root = Path.expand("../support/fixtures/workflows_no_deploy", __DIR__)
      File.mkdir_p!(no_deploy_root)
      File.cp!(Path.join(@fixtures_root, "no_deploy.yml"), Path.join(no_deploy_root, "no_deploy.yml"))

      result = GitHubActions.find_build_workflow(no_deploy_root, "qa-foo")
      assert {:error, %ErrorMessage{code: :not_found}} = result

      File.rm_rf!(no_deploy_root)
    end
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `mix test test/deploy_ex/github_actions_test.exs --only describe:"find_build_workflow/2"`
Expected: FAIL — `find_build_workflow/2` is undefined.

- [ ] **Step 3: Implement `find_build_workflow/2`**

Append to `lib/deploy_ex/github_actions.ex` (add to module, before the existing `defp escape_segment`):

```elixir
  @release_command_signature "mix deploy_ex.release"

  @doc """
  Scans `<workflows_root>/*.yml` and returns `{:ok, %{file:, job_id:}}` for the
  workflow + job that builds a release for `qa_branch`.

  Detection logic:
  1. Parse each workflow file.
  2. Keep workflows whose `on.push.branches` patterns match `qa_branch` via
     `branch_glob_match?/2`.
  3. Among those, find a job whose steps include a `run:` containing
     `mix deploy_ex.release` — either directly OR by following a
     `uses: ./.github/workflows/<sub>.yml` reference into the sub-workflow's
     run steps.
  4. If exactly one candidate matches, return it. If multiple, return :conflict.
     If none, return :not_found.
  """
  @spec find_build_workflow(Path.t(), String.t()) :: {:ok, %{file: String.t(), job_id: String.t()}} | {:error, ErrorMessage.t()}
  def find_build_workflow(workflows_root, qa_branch) do
    workflows = list_workflows(workflows_root)

    candidates =
      workflows
      |> Enum.filter(&workflow_triggers_on_branch?(&1, qa_branch))
      |> Enum.flat_map(&find_release_jobs(&1, workflows))

    case candidates do
      [%{file: _, job_id: _} = match] ->
        {:ok, match}

      [] ->
        {:error,
         ErrorMessage.not_found(
           "no workflow runs `#{@release_command_signature}` for branch #{qa_branch}",
           %{workflows_scanned: Enum.map(workflows, & &1.basename)}
         )}

      multiple ->
        {:error,
         ErrorMessage.conflict(
           "multiple workflows match for branch #{qa_branch}; pass --build-workflow to disambiguate",
           %{candidates: multiple}
         )}
    end
  end

  defp list_workflows(workflows_root) do
    workflows_root
    |> Path.join("*.{yml,yaml}")
    |> Path.wildcard()
    |> Enum.map(&parse_workflow/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_workflow(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, parsed} -> %{basename: Path.basename(path), path: path, parsed: parsed}
      {:error, _} -> nil
    end
  end

  defp workflow_triggers_on_branch?(%{parsed: parsed}, branch) do
    parsed
    |> get_in(["on", "push", "branches"])
    |> List.wrap()
    |> Enum.any?(&branch_glob_match?(&1, branch))
  end

  defp find_release_jobs(%{basename: basename, parsed: parsed}, all_workflows) do
    parsed
    |> Map.get("jobs", %{})
    |> Enum.filter(fn {_id, job} -> job_runs_release?(job, all_workflows) end)
    |> Enum.map(fn {id, _job} -> %{file: basename, job_id: id} end)
  end

  defp job_runs_release?(%{"steps" => steps}, _all) when is_list(steps) do
    Enum.any?(steps, &step_runs_release?/1)
  end

  defp job_runs_release?(%{"uses" => "./" <> sub_path}, all_workflows) do
    sub_basename = Path.basename(sub_path)

    case Enum.find(all_workflows, &(&1.basename === sub_basename)) do
      nil -> false
      sub -> Map.get(sub.parsed, "jobs", %{}) |> Enum.any?(fn {_id, job} -> job_runs_release?(job, all_workflows) end)
    end
  end

  defp job_runs_release?(_job, _all), do: false

  defp step_runs_release?(%{"run" => run}) when is_binary(run) do
    String.contains?(run, @release_command_signature)
  end

  defp step_runs_release?(_step), do: false
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `mix test test/deploy_ex/github_actions_test.exs`
Expected: 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/github_actions.ex test/deploy_ex/github_actions_test.exs
git commit -m "feat(github_actions): add find_build_workflow with sub-workflow resolution"
```

---

## Task 5: Extend `ToolInstaller` for `:gh`

**Files:**
- Modify: `lib/deploy_ex/tool_installer.ex`
- Modify: `test/deploy_ex/tool_installer_test.exs`

- [ ] **Step 1: Write failing tests for `:gh`**

Append to `test/deploy_ex/tool_installer_test.exs` (inside the existing test module):

```elixir
  describe "install_command/2 :gh" do
    test "returns brew install for macOS" do
      assert {"brew install gh", "."} = DeployEx.ToolInstaller.install_command(:gh, :macos)
    end

    test "returns apt install pipeline for Debian" do
      {cmd, _dir} = DeployEx.ToolInstaller.install_command(:gh, :debian)
      assert cmd =~ "apt"
      assert cmd =~ "gh"
    end

    test "returns error for Windows" do
      assert {:error, %ErrorMessage{code: :bad_request}} = DeployEx.ToolInstaller.install_command(:gh, :windows)
    end
  end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `mix test test/deploy_ex/tool_installer_test.exs`
Expected: 3 new failures (no install_command for :gh).

- [ ] **Step 3: Add `:gh` clauses to `install_command/2`**

In `lib/deploy_ex/tool_installer.ex`, add (search for `install_command(:terraform, :macos)` to find the section):

```elixir
  def install_command(:gh, :macos), do: {"brew install gh", "."}

  def install_command(:gh, :debian) do
    cmd = Enum.join([
      "type -p curl >/dev/null || (sudo apt update && sudo apt install -y curl)",
      "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg",
      "sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null",
      "sudo apt update",
      "sudo apt install -y gh"
    ], " && ")

    {cmd, "."}
  end

  def install_command(:gh, :alpine), do: {"sudo apk add --no-cache github-cli", "."}
  def install_command(:gh, :amazon_linux), do: {"sudo dnf install -y gh", "."}
```

Then add an `ensure_installed(:gh)` clause near the existing `ensure_installed/1` clauses:

```elixir
  def ensure_installed(:gh) do
    case System.find_executable("gh") do
      nil -> install_tool(:gh)
      _path -> :ok
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/deploy_ex/tool_installer_test.exs`
Expected: all tests pass (existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/tool_installer.ex test/deploy_ex/tool_installer_test.exs
git commit -m "feat(tool_installer): add :gh install support for macos/debian/alpine/amazon"
```

---

## Task 6: `GitHubActions.ensure_authenticated/0`

**Files:**
- Modify: `lib/deploy_ex/github_actions.ex`
- Modify: `test/deploy_ex/github_actions_test.exs`

The implementation shells out to `gh auth status`. Tests inject a fake shell function via `opts[:shell]` to avoid hitting real `gh`.

- [ ] **Step 1: Write failing test**

Append to `test/deploy_ex/github_actions_test.exs`:

```elixir
  describe "ensure_authenticated/1" do
    test "returns :ok when gh auth status exits 0" do
      shell = fn "gh auth status", _dir, _opts -> {:ok, "Logged in to github.com as foo"} end
      assert :ok = GitHubActions.ensure_authenticated(shell: shell)
    end

    test "returns error with hint when gh auth status fails" do
      shell = fn "gh auth status", _dir, _opts ->
        {:error, ErrorMessage.internal_server_error("not logged in", %{})}
      end

      assert {:error, %ErrorMessage{code: :unauthorized, message: msg}} =
               GitHubActions.ensure_authenticated(shell: shell)

      assert msg =~ "gh auth login"
    end
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `mix test test/deploy_ex/github_actions_test.exs --only describe:"ensure_authenticated/1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Append to `lib/deploy_ex/github_actions.ex`:

```elixir
  @doc """
  Checks `gh auth status`. Returns `:ok` if logged in, otherwise an
  `:unauthorized` ErrorMessage hinting at `gh auth login`.

  `opts[:shell]` injects a `(command, dir, opts) -> {:ok, output} | {:error, ErrorMessage}`
  function for testing. Defaults to `DeployEx.Utils.run_command_with_return/3`.
  """
  @spec ensure_authenticated(keyword()) :: :ok | {:error, ErrorMessage.t()}
  def ensure_authenticated(opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)

    case shell.("gh auth status", ".", []) do
      {:ok, _output} ->
        :ok

      {:error, _error} ->
        {:error,
         ErrorMessage.unauthorized(
           "gh CLI is not authenticated. Run: gh auth login",
           %{}
         )}
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/deploy_ex/github_actions_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/github_actions.ex test/deploy_ex/github_actions_test.exs
git commit -m "feat(github_actions): add ensure_authenticated wrapper"
```

---

## Task 7: `GitHubActions.find_run_id/4`

**Files:**
- Modify: `lib/deploy_ex/github_actions.ex`
- Modify: `test/deploy_ex/github_actions_test.exs`

- [ ] **Step 1: Write failing tests**

Append:

```elixir
  describe "find_run_id/4" do
    test "returns the run_id from gh run list output" do
      shell = fn cmd, _dir, _opts ->
        assert cmd =~ "gh run list"
        assert cmd =~ "--branch=qa/cfx_web-canary"
        assert cmd =~ "--commit=abc1234"
        assert cmd =~ "--workflow=pipeline.yml"
        {:ok, ~s([{"databaseId":12345,"status":"in_progress","conclusion":null,"name":"Pipeline"}])}
      end

      assert {:ok, 12345} =
               GitHubActions.find_run_id("qa/cfx_web-canary", "abc1234", "pipeline.yml",
                 shell: shell,
                 retry_interval_ms: 0,
                 retry_max: 1
               )
    end

    test "retries while no run is found, succeeds on second attempt" do
      counter = :counters.new(1, [])

      shell = fn _cmd, _dir, _opts ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) === 1 do
          {:ok, "[]"}
        else
          {:ok, ~s([{"databaseId":99,"status":"queued","conclusion":null,"name":"P"}])}
        end
      end

      assert {:ok, 99} =
               GitHubActions.find_run_id("b", "s", "w.yml",
                 shell: shell,
                 retry_interval_ms: 0,
                 retry_max: 5
               )
    end

    test "returns :not_found after retry budget exhausted" do
      shell = fn _cmd, _dir, _opts -> {:ok, "[]"} end

      assert {:error, %ErrorMessage{code: :not_found}} =
               GitHubActions.find_run_id("b", "s", "w.yml",
                 shell: shell,
                 retry_interval_ms: 0,
                 retry_max: 3
               )
    end
  end
```

- [ ] **Step 2: Run tests, verify failures**

Run: `mix test test/deploy_ex/github_actions_test.exs --only describe:"find_run_id/4"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Append to `lib/deploy_ex/github_actions.ex`:

```elixir
  @default_retry_interval_ms 5_000
  @default_retry_max 12

  @doc """
  Looks up the GitHub Actions run ID for the most recent run matching
  `branch` + `sha` + `workflow_file`. Retries up to `retry_max` times every
  `retry_interval_ms` if no run is found yet (the run takes a few seconds to
  register after `git push`).

  `opts[:shell]` injects a fake shell for tests.
  """
  @spec find_run_id(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, ErrorMessage.t()}
  def find_run_id(branch, sha, workflow_file, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)
    retry_interval_ms = Keyword.get(opts, :retry_interval_ms, @default_retry_interval_ms)
    retry_max = Keyword.get(opts, :retry_max, @default_retry_max)

    cmd =
      "gh run list --branch=#{branch} --commit=#{sha} --workflow=#{workflow_file} " <>
        "--json databaseId,status,conclusion,name --limit 1"

    Enum.reduce_while(1..retry_max, nil, fn attempt, _acc ->
      case shell.(cmd, ".", []) do
        {:ok, output} ->
          case extract_run_id(output) do
            {:ok, _id} = ok -> {:halt, ok}
            :not_yet when attempt < retry_max ->
              Process.sleep(retry_interval_ms)
              {:cont, nil}

            :not_yet ->
              {:halt,
               {:error,
                ErrorMessage.not_found(
                  "no workflow run found for #{branch} @ #{sha} after #{retry_max} attempts",
                  %{branch: branch, sha: sha, workflow: workflow_file}
                )}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp extract_run_id(json_output) do
    case Jason.decode(json_output) do
      {:ok, [%{"databaseId" => id} | _]} -> {:ok, id}
      {:ok, []} -> :not_yet
      {:error, _} -> :not_yet
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/deploy_ex/github_actions_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/github_actions.ex test/deploy_ex/github_actions_test.exs
git commit -m "feat(github_actions): add find_run_id with retry-until-registered"
```

---

## Task 8: `GitHubActions.wait_for_run/3`

**Files:**
- Modify: `lib/deploy_ex/github_actions.ex`
- Modify: `test/deploy_ex/github_actions_test.exs`

- [ ] **Step 1: Write failing tests**

Append:

```elixir
  describe "wait_for_run/3" do
    @successful_run %{
      "status" => "completed",
      "conclusion" => "success",
      "jobs" => [
        %{"name" => "deploy-qa", "status" => "completed", "conclusion" => "success"}
      ]
    }

    @target_failed_run %{
      "status" => "completed",
      "conclusion" => "failure",
      "jobs" => [
        %{"name" => "deploy-qa", "status" => "completed", "conclusion" => "failure"}
      ]
    }

    @dep_failed_run %{
      "status" => "in_progress",
      "conclusion" => nil,
      "jobs" => [
        %{"name" => "mix-compile-prod", "status" => "completed", "conclusion" => "failure"},
        %{"name" => "deploy-qa", "status" => "queued", "conclusion" => nil}
      ]
    }

    test "returns {:ok, run} when target job conclusion is success" do
      shell = fn _cmd, _dir, _opts -> {:ok, Jason.encode!(@successful_run)} end

      assert {:ok, _run} =
               GitHubActions.wait_for_run(123, "deploy-qa",
                 shell: shell,
                 poll_interval_ms: 0,
                 timeout_ms: 1_000
               )
    end

    test "returns :build_failed when target job conclusion is failure" do
      shell = fn _cmd, _dir, _opts -> {:ok, Jason.encode!(@target_failed_run)} end

      assert {:error, :build_failed} =
               GitHubActions.wait_for_run(123, "deploy-qa",
                 shell: shell,
                 poll_interval_ms: 0,
                 timeout_ms: 1_000
               )
    end

    test "aborts early when a non-target job fails (dep would skip target)" do
      shell = fn _cmd, _dir, _opts -> {:ok, Jason.encode!(@dep_failed_run)} end

      assert {:error, :build_failed} =
               GitHubActions.wait_for_run(123, "deploy-qa",
                 shell: shell,
                 poll_interval_ms: 0,
                 timeout_ms: 1_000
               )
    end

    test "returns :timeout when timeout_ms exceeded" do
      shell = fn _cmd, _dir, _opts ->
        {:ok, Jason.encode!(%{"status" => "in_progress", "conclusion" => nil, "jobs" => []})}
      end

      assert {:error, :timeout} =
               GitHubActions.wait_for_run(123, "deploy-qa",
                 shell: shell,
                 poll_interval_ms: 1,
                 timeout_ms: 5
               )
    end
  end
```

- [ ] **Step 2: Run tests, verify failures**

Run: `mix test test/deploy_ex/github_actions_test.exs --only describe:"wait_for_run/3"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Append:

```elixir
  @default_poll_interval_ms 15_000
  @default_timeout_ms 30 * 60 * 1_000

  @doc """
  Polls `gh run view <run_id> --json status,conclusion,jobs` and returns
  `{:ok, run}` when the target job conclusion is success, `{:error, :build_failed}`
  if the target or any non-target job fails (which would skip the target),
  or `{:error, :timeout}` after `timeout_ms`.

  Options:
  * `:poll_interval_ms` — default 15_000
  * `:timeout_ms` — default 30 * 60 * 1_000 (30 min)
  * `:log_fn` — `(line :: String.t() -> any)` per-poll status emitter
  * `:shell` — test shim
  """
  @spec wait_for_run(integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :build_failed | :timeout | ErrorMessage.t()}
  def wait_for_run(run_id, target_job_name, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    log_fn = Keyword.get(opts, :log_fn, fn _line -> :ok end)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_loop(run_id, target_job_name, deadline, poll_interval_ms, shell, log_fn)
  end

  defp poll_loop(run_id, target_job_name, deadline, interval_ms, shell, log_fn) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case fetch_run(run_id, shell) do
        {:ok, run} -> evaluate_run(run, target_job_name, deadline, interval_ms, shell, log_fn, run_id)
        {:error, _} = err -> err
      end
    end
  end

  defp fetch_run(run_id, shell) do
    cmd = "gh run view #{run_id} --json status,conclusion,jobs"

    case shell.(cmd, ".", []) do
      {:ok, output} -> Jason.decode(output)
      {:error, _} = err -> err
    end
  end

  defp evaluate_run(run, target_job_name, deadline, interval_ms, shell, log_fn, run_id) do
    jobs = Map.get(run, "jobs", [])
    log_jobs(jobs, log_fn)

    cond do
      any_job_failed?(jobs) -> {:error, :build_failed}
      target_succeeded?(jobs, target_job_name) -> {:ok, run}
      true ->
        Process.sleep(interval_ms)
        poll_loop(run_id, target_job_name, deadline, interval_ms, shell, log_fn)
    end
  end

  defp any_job_failed?(jobs) do
    Enum.any?(jobs, fn job ->
      Map.get(job, "conclusion") in ["failure", "cancelled", "skipped"]
    end)
  end

  defp target_succeeded?(jobs, name) do
    Enum.any?(jobs, fn job ->
      Map.get(job, "name") === name and Map.get(job, "conclusion") === "success"
    end)
  end

  defp log_jobs(jobs, log_fn) do
    Enum.each(jobs, fn job ->
      log_fn.("#{Map.get(job, "name")}: #{Map.get(job, "status")} (#{Map.get(job, "conclusion") || "—"})")
    end)
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/deploy_ex/github_actions_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/github_actions.ex test/deploy_ex/github_actions_test.exs
git commit -m "feat(github_actions): add wait_for_run with early-abort on dep failure"
```

---

## Task 9: `GitOperations.resolve_qa_branch/4`

**Files:**
- Create: `lib/deploy_ex/git_operations.ex`
- Create: `test/deploy_ex/git_operations_test.exs`

- [ ] **Step 1: Write failing tests**

In `test/deploy_ex/git_operations_test.exs`:

```elixir
defmodule DeployEx.GitOperationsTest do
  use ExUnit.Case, async: true

  alias DeployEx.GitOperations

  describe "resolve_qa_branch/4" do
    test "reuses current branch when it matches qa/" do
      shell = fn "git rev-parse --abbrev-ref HEAD", _dir, _opts -> {:ok, "qa/foo\n"} end

      assert {:reuse_current, "qa/foo"} =
               GitOperations.resolve_qa_branch("/repo", "cfx_web", "canary", "abc1234567",
                 shell: shell
               )
    end

    test "reuses current branch when it matches qa-" do
      shell = fn _cmd, _dir, _opts -> {:ok, "qa-experimental"} end

      assert {:reuse_current, "qa-experimental"} =
               GitOperations.resolve_qa_branch("/repo", "cfx_web", nil, "deadbeef",
                 shell: shell
               )
    end

    test "creates new branch with --tag when not on a qa branch" do
      shell = fn _cmd, _dir, _opts -> {:ok, "main\n"} end

      assert {:create_new, "qa/cfx_web-canary"} =
               GitOperations.resolve_qa_branch("/repo", "cfx_web", "canary", "abc1234567",
                 shell: shell
               )
    end

    test "creates new branch with short sha when no --tag" do
      shell = fn _cmd, _dir, _opts -> {:ok, "main"} end

      assert {:create_new, "qa/cfx_web-abc1234"} =
               GitOperations.resolve_qa_branch("/repo", "cfx_web", nil, "abc1234567",
                 shell: shell
               )
    end
  end
end
```

- [ ] **Step 2: Run tests, verify failures**

Run: `mix test test/deploy_ex/git_operations_test.exs`
Expected: FAIL — module not defined.

- [ ] **Step 3: Implement**

In `lib/deploy_ex/git_operations.ex`:

```elixir
defmodule DeployEx.GitOperations do
  @moduledoc """
  Git operations for the QA pipeline: resolve which branch to push QA rewrites
  to, commit + push specific files, revert the rewrite commit, and delete
  remote branches.

  All shell-outs go through `opts[:shell]`, defaulting to
  `DeployEx.Utils.run_command_with_return/3`. This makes the module fully
  testable without hitting a real git repo.
  """

  @qa_branch_pattern ~r/^qa[\/-]/

  @doc """
  Determines whether to reuse the current branch (if it matches `^qa[\\/-]`)
  or create a new branch derived from `app_name` + `tag` (or short SHA if
  `tag` is nil).
  """
  @spec resolve_qa_branch(Path.t(), String.t(), String.t() | nil, String.t(), keyword()) ::
          {:reuse_current, String.t()} | {:create_new, String.t()}
  def resolve_qa_branch(repo_root, app_name, tag, sha, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)

    case shell.("git rev-parse --abbrev-ref HEAD", repo_root, []) do
      {:ok, output} ->
        current = String.trim(output)

        if Regex.match?(@qa_branch_pattern, current) do
          {:reuse_current, current}
        else
          {:create_new, derive_qa_branch_name(app_name, tag, sha)}
        end

      {:error, _} ->
        {:create_new, derive_qa_branch_name(app_name, tag, sha)}
    end
  end

  defp derive_qa_branch_name(app_name, nil, sha), do: "qa/#{app_name}-#{String.slice(sha, 0, 7)}"
  defp derive_qa_branch_name(app_name, tag, _sha) when is_binary(tag), do: "qa/#{app_name}-#{tag}"
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/deploy_ex/git_operations_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/git_operations.ex test/deploy_ex/git_operations_test.exs
git commit -m "feat(git_operations): add resolve_qa_branch with current-branch reuse"
```

---

## Task 10: `GitOperations.commit_and_push/5`

**Files:**
- Modify: `lib/deploy_ex/git_operations.ex`
- Modify: `test/deploy_ex/git_operations_test.exs`

- [ ] **Step 1: Write failing tests**

Append:

```elixir
  describe "commit_and_push/5" do
    test "creates new branch from base_sha, stages files, force-with-lease push" do
      commands_run = :counters.new(1, [])
      log = :ets.new(:log, [:public, :ordered_set])

      shell = fn cmd, _dir, _opts ->
        idx = :counters.add(commands_run, 1, 1) || :counters.get(commands_run, 1)
        :ets.insert(log, {idx, cmd})

        cond do
          cmd =~ "git checkout -B" -> {:ok, ""}
          cmd =~ "git add" -> {:ok, ""}
          cmd =~ "git commit" -> {:ok, ""}
          cmd =~ "git push" -> {:ok, ""}
          cmd =~ "git rev-parse HEAD" -> {:ok, "newsha1234567890\n"}
        end
      end

      result =
        GitOperations.commit_and_push(
          "/repo",
          "qa/cfx_web-canary",
          ["apps/cfx_web/config/prod.exs"],
          "qa: rewrite host config for cfx_web",
          shell: shell,
          create_new?: true,
          base_sha: "deadbeef"
        )

      assert {:ok, "newsha1234567890"} = result

      cmds = :ets.tab2list(log) |> Enum.sort() |> Enum.map(fn {_i, c} -> c end)
      assert Enum.any?(cmds, &(&1 =~ "git checkout -B qa/cfx_web-canary deadbeef"))
      assert Enum.any?(cmds, &(&1 =~ "git add"))
      assert Enum.any?(cmds, &(&1 =~ "git push --force-with-lease -u origin qa/cfx_web-canary"))
    end

    test "regular push for reused branch (no checkout, no force)" do
      shell = fn cmd, _dir, _opts ->
        cond do
          cmd =~ "git add" -> {:ok, ""}
          cmd =~ "git commit" -> {:ok, ""}
          cmd =~ "git push" ->
            refute cmd =~ "force"
            refute cmd =~ "checkout"
            {:ok, ""}

          cmd =~ "git rev-parse HEAD" -> {:ok, "abc\n"}
        end
      end

      assert {:ok, "abc"} =
               GitOperations.commit_and_push(
                 "/repo",
                 "qa-existing",
                 ["foo.exs"],
                 "msg",
                 shell: shell,
                 create_new?: false
               )
    end

    test "stages only the listed files" do
      seen_add_cmd = :ets.new(:add, [:public])

      shell = fn cmd, _dir, _opts ->
        if cmd =~ "git add" do
          :ets.insert(seen_add_cmd, {:cmd, cmd})
        end

        cond do
          cmd =~ "git rev-parse HEAD" -> {:ok, "x"}
          true -> {:ok, ""}
        end
      end

      _ =
        GitOperations.commit_and_push(
          "/repo",
          "b",
          ["a.exs", "b.exs"],
          "m",
          shell: shell,
          create_new?: false
        )

      [{:cmd, add_cmd}] = :ets.tab2list(seen_add_cmd)
      assert add_cmd =~ "a.exs"
      assert add_cmd =~ "b.exs"
      refute add_cmd =~ "git add -A"
      refute add_cmd =~ "git add ."
    end
  end
```

- [ ] **Step 2: Run tests, verify failures**

Run: `mix test test/deploy_ex/git_operations_test.exs --only describe:"commit_and_push/5"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Append to `lib/deploy_ex/git_operations.ex`:

```elixir
  @doc """
  Stages the listed `files`, commits with `message`, and pushes `branch` to
  origin. Returns the resulting commit's SHA.

  Options:
  * `:create_new?` — true if we created the branch (uses `--force-with-lease`).
  * `:base_sha` — when `:create_new?`, branch off this SHA via `git checkout -B`.
  * `:shell` — test shim.
  """
  @spec commit_and_push(Path.t(), String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, String.t()} | {:error, ErrorMessage.t()}
  def commit_and_push(repo_root, branch, files, message, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)
    create_new? = Keyword.get(opts, :create_new?, false)
    base_sha = Keyword.get(opts, :base_sha)

    with :ok <- maybe_checkout_branch(shell, repo_root, branch, create_new?, base_sha),
         :ok <- run_step(shell, repo_root, "git add #{quote_files(files)}"),
         :ok <- run_step(shell, repo_root, ~s|git commit -m #{shell_escape(message)}|),
         :ok <- run_step(shell, repo_root, push_command(branch, create_new?)),
         {:ok, sha_output} <- shell.("git rev-parse HEAD", repo_root, []) do
      {:ok, String.trim(sha_output)}
    end
  end

  defp maybe_checkout_branch(_shell, _repo, _branch, false, _base), do: :ok

  defp maybe_checkout_branch(shell, repo, branch, true, nil) do
    run_step(shell, repo, "git checkout -B #{branch}")
  end

  defp maybe_checkout_branch(shell, repo, branch, true, base_sha) do
    run_step(shell, repo, "git checkout -B #{branch} #{base_sha}")
  end

  defp push_command(branch, true), do: "git push --force-with-lease -u origin #{branch}"
  defp push_command(_branch, false), do: "git push"

  defp run_step(shell, repo, cmd) do
    case shell.(cmd, repo, []) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp quote_files(files), do: files |> Enum.map(&shell_escape/1) |> Enum.join(" ")

  defp shell_escape(s), do: ~s|'#{String.replace(s, "'", "'\\''")}'|
```

- [ ] **Step 4: Run tests**

Run: `mix test test/deploy_ex/git_operations_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/git_operations.ex test/deploy_ex/git_operations_test.exs
git commit -m "feat(git_operations): add commit_and_push with create-new vs reuse semantics"
```

---

## Task 11: `GitOperations.revert_and_push/2` + `delete_remote_branch/2`

**Files:**
- Modify: `lib/deploy_ex/git_operations.ex`
- Modify: `test/deploy_ex/git_operations_test.exs`

- [ ] **Step 1: Write failing tests**

Append:

```elixir
  describe "revert_and_push/2" do
    test "runs git revert HEAD --no-edit && git push" do
      seen = :ets.new(:s, [:public, :ordered_set])

      shell = fn cmd, _dir, _opts ->
        :ets.insert(seen, {System.unique_integer([:monotonic]), cmd})
        {:ok, ""}
      end

      assert :ok = GitOperations.revert_and_push("/repo", shell: shell)

      cmds = :ets.tab2list(seen) |> Enum.sort() |> Enum.map(fn {_, c} -> c end)
      assert Enum.any?(cmds, &(&1 === "git revert HEAD --no-edit"))
      assert Enum.any?(cmds, &(&1 === "git push"))
    end
  end

  describe "delete_remote_branch/2" do
    test "runs git push origin --delete <branch>" do
      shell = fn cmd, _dir, _opts ->
        assert cmd === "git push origin --delete qa/cfx_web-canary"
        {:ok, ""}
      end

      assert :ok = GitOperations.delete_remote_branch("/repo", "qa/cfx_web-canary", shell: shell)
    end
  end
```

- [ ] **Step 2: Run tests, verify failures**

Run: `mix test test/deploy_ex/git_operations_test.exs`
Expected: 2 new failures.

- [ ] **Step 3: Implement**

Append to `lib/deploy_ex/git_operations.ex`:

```elixir
  @doc """
  Reverts HEAD with `--no-edit` (no commit message editor) then pushes.
  No force, no rewrite — leaves an audit trail.
  """
  @spec revert_and_push(Path.t(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def revert_and_push(repo_root, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)

    with :ok <- run_step(shell, repo_root, "git revert HEAD --no-edit"),
         :ok <- run_step(shell, repo_root, "git push") do
      :ok
    end
  end

  @doc """
  Deletes a branch from origin via `git push origin --delete <branch>`.
  """
  @spec delete_remote_branch(Path.t(), String.t(), keyword()) :: :ok | {:error, ErrorMessage.t()}
  def delete_remote_branch(repo_root, branch, opts \\ []) do
    shell = Keyword.get(opts, :shell, &DeployEx.Utils.run_command_with_return/3)
    run_step(shell, repo_root, "git push origin --delete #{branch}")
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/deploy_ex/git_operations_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/deploy_ex/git_operations.ex test/deploy_ex/git_operations_test.exs
git commit -m "feat(git_operations): add revert_and_push + delete_remote_branch"
```

---

## Task 12: New CLI flags + validation in `qa.create.ex`

**Files:**
- Modify: `lib/mix/tasks/deploy_ex.qa.create.ex`
- Modify: `test/mix/tasks/deploy_ex_qa_create_test.exs`

- [ ] **Step 1: Write failing test for parse_args**

In `test/mix/tasks/deploy_ex_qa_create_test.exs`, append a new describe block:

```elixir
  describe "parse_args/1 wait-for-build options" do
    test "--wait-for-build parses to opts[:wait_for_build]" do
      {opts, _} = parse_args(["--wait-for-build"])
      assert opts[:wait_for_build] === true
    end

    test "--build-workflow parses to opts[:build_workflow]" do
      {opts, _} = parse_args(["--build-workflow", "pipeline.yml"])
      assert opts[:build_workflow] === "pipeline.yml"
    end

    test "--build-job parses to opts[:build_job]" do
      {opts, _} = parse_args(["--build-job", "deploy-qa"])
      assert opts[:build_job] === "deploy-qa"
    end

    test "--build-timeout parses to opts[:build_timeout]" do
      {opts, _} = parse_args(["--build-timeout", "60"])
      assert opts[:build_timeout] === 60
    end
  end
```

Update the test's local `parse_args/1` mirror to add the new switches:

```elixir
  defp parse_args(args) do
    OptionParser.parse!(args,
      aliases: [s: :sha, t: :tag, f: :force, q: :quiet],
      switches: [
        sha: :string,
        tag: :string,
        instance_type: :string,
        skip_setup: :boolean,
        skip_deploy: :boolean,
        skip_ami: :boolean,
        attach_lb: :boolean,
        force: :boolean,
        quiet: :boolean,
        aws_region: :string,
        aws_release_bucket: :string,
        no_tui: :boolean,
        public_ip_cert: :boolean,
        wait_for_build: :boolean,
        build_workflow: :string,
        build_job: :string,
        build_timeout: :integer
      ]
    )
  end
```

- [ ] **Step 2: Run tests, verify failures**

Run: `mix test test/mix/tasks/deploy_ex_qa_create_test.exs --only describe:"parse_args/1 wait-for-build options"`
Expected: FAIL — current task switches missing the new ones.

- [ ] **Step 3: Update the task's `parse_args/1`**

In `lib/mix/tasks/deploy_ex.qa.create.ex`, find the existing `defp parse_args/1` and add to the `switches:` list (after the existing entries, before the closing `]`):

```elixir
        wait_for_build: :boolean,
        build_workflow: :string,
        build_job: :string,
        build_timeout: :integer
```

- [ ] **Step 4: Run tests**

Run: `mix test test/mix/tasks/deploy_ex_qa_create_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/deploy_ex.qa.create.ex test/mix/tasks/deploy_ex_qa_create_test.exs
git commit -m "feat(qa.create): parse --wait-for-build/--build-workflow/--build-job/--build-timeout"
```

---

## Task 13: Pre-flight validation step (5–8)

**Files:**
- Modify: `lib/mix/tasks/deploy_ex.qa.create.ex`

These steps run BEFORE EC2 provisioning so a misconfigured workflow / dirty tree / missing `gh` fails fast.

- [ ] **Step 1: Add a `validate_wait_for_build_preconditions/3` private function**

Insert near the existing pre-flight helpers (around `check_llm_configured_or_raise/0`):

```elixir
  defp validate_wait_for_build_preconditions(_opts, _umbrella_root, _app_name, false), do: {:ok, %{enabled?: false}}

  defp validate_wait_for_build_preconditions(opts, umbrella_root, app_name, true) do
    with :ok <- DeployEx.ToolInstaller.ensure_installed(:gh),
         :ok <- DeployEx.GitHubActions.ensure_authenticated(),
         {:ok, branch_resolution} <- resolve_branch(opts, umbrella_root, app_name),
         {:ok, %{} = workflow} <- detect_or_override_workflow(opts, umbrella_root, branch_resolution) do
      {:ok,
       %{
         enabled?: true,
         workflow: workflow,
         branch_resolution: branch_resolution
       }}
    end
  end

  defp detect_or_override_workflow(opts, umbrella_root, {_action, branch}) do
    workflows_root = Path.join(umbrella_root, ".github/workflows")

    case {opts[:build_workflow], opts[:build_job]} do
      {wf, job} when is_binary(wf) and is_binary(job) ->
        {:ok, %{file: wf, job_id: job}}

      _ ->
        DeployEx.GitHubActions.find_build_workflow(workflows_root, branch)
    end
  end

  defp resolve_branch(opts, umbrella_root, app_name) do
    sha = opts[:sha] || head_sha(umbrella_root)
    tag = opts[:tag]

    case DeployEx.GitOperations.resolve_qa_branch(umbrella_root, app_name, tag, sha) do
      {:reuse_current, b} = result ->
        if opts[:sha] && opts[:sha] !== sha do
          {:error,
           ErrorMessage.bad_request(
             "already on qa branch #{b}; --sha conflicts with HEAD. Drop --sha or checkout a different branch first.",
             %{}
           )}
        else
          {:ok, result}
        end

      {:create_new, _b} = result ->
        {:ok, result}
    end
  end

  defp head_sha(repo_root) do
    case DeployEx.Utils.run_command_with_return("git rev-parse HEAD", repo_root) do
      {:ok, sha} -> String.trim(sha)
      _ -> "HEAD"
    end
  end
```

- [ ] **Step 2: Wire it into the pipeline**

Find the existing pipeline orchestrator (`run_qa_pipeline_work/4` or equivalent) and insert a new step after step 4 (confirm target files), before step 5 (gather infra). Update `@pipeline_total_steps` to 18 when `opts[:wait_for_build]` is true.

```elixir
  @pipeline_total_steps_base 12
  @pipeline_total_steps_wait_for_build 18

  defp pipeline_total_steps(opts) do
    if opts[:wait_for_build], do: @pipeline_total_steps_wait_for_build, else: @pipeline_total_steps_base
  end

  # In the pipeline:
  Progress.advance(tui_pid, "Validating wait-for-build preconditions...")
  {:ok, build_state} =
    validate_wait_for_build_preconditions(opts, umbrella_root, app_name, opts[:wait_for_build] || false)
```

- [ ] **Step 3: Compile, no test yet (integration tested in Task 17)**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/deploy_ex.qa.create.ex
git commit -m "feat(qa.create): add pre-flight validation for --wait-for-build"
```

---

## Task 14: Commit + push step (14)

**Files:**
- Modify: `lib/mix/tasks/deploy_ex.qa.create.ex`

- [ ] **Step 1: Add a helper to commit + push the rewritten files**

```elixir
  defp commit_and_push_rewrites(_qa_node, _build_state, _entries, false, _tui_pid), do: {:ok, nil}

  defp commit_and_push_rewrites(qa_node, build_state, entries, true, tui_pid) do
    Progress.advance(tui_pid, "Committing & pushing QA branch...")

    {action, branch} = build_state.branch_resolution
    files = Enum.map(entries, & &1.path)
    short = String.slice(qa_node.target_sha || "", 0, 7)
    message = "qa: rewrite host config for #{qa_node.app_name} (#{short})"

    base_sha = if action === :create_new, do: qa_node.target_sha, else: nil

    DeployEx.GitOperations.commit_and_push(
      umbrella_root(),
      branch,
      files,
      message,
      create_new?: action === :create_new,
      base_sha: base_sha
    )
  end

  defp umbrella_root, do: File.cwd!()
```

- [ ] **Step 2: Insert into pipeline after `apply_host_rewrite`**

Wire it so that `entries` (returned by `QaHostRewrite.apply_proposals/4`) flow into `commit_and_push_rewrites/5`. Capture the new SHA into `qa_node`:

```elixir
  {:ok, entries} = DeployEx.QaHostRewrite.apply_proposals(accepted, qa_node.public_ip, backup_dir)

  qa_node =
    case commit_and_push_rewrites(qa_node, build_state, entries, opts[:wait_for_build] || false, tui_pid) do
      {:ok, nil} -> qa_node
      {:ok, new_sha} -> %{qa_node | target_sha: new_sha}
      {:error, error} -> raise inspect(error)
    end
```

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/deploy_ex.qa.create.ex
git commit -m "feat(qa.create): commit & push QA branch when --wait-for-build"
```

---

## Task 15: Wait-for-build step (15) — success path

**Files:**
- Modify: `lib/mix/tasks/deploy_ex.qa.create.ex`

- [ ] **Step 1: Add a helper for the wait step**

```elixir
  defp wait_for_build(_qa_node, _build_state, false, _opts, _tui_pid), do: {:ok, :skipped}

  defp wait_for_build(qa_node, build_state, true, opts, tui_pid) do
    Progress.advance(tui_pid, "Waiting for build workflow...")
    {_, branch} = build_state.branch_resolution
    %{file: workflow_file, job_id: job_id} = build_state.workflow

    log_fn = fn line -> Progress.update_log(tui_pid, "  " <> line) end
    timeout_ms = (opts[:build_timeout] || 30) * 60 * 1_000

    with {:ok, run_id} <- DeployEx.GitHubActions.find_run_id(branch, qa_node.target_sha, workflow_file),
         {:ok, _run} <-
           DeployEx.GitHubActions.wait_for_run(run_id, job_id,
             log_fn: log_fn,
             timeout_ms: timeout_ms
           ) do
      {:ok, run_id}
    else
      {:error, reason} -> {:error, %{reason: reason, run_id: find_known_run_id(branch, qa_node.target_sha, workflow_file)}}
    end
  end

  defp find_known_run_id(branch, sha, workflow_file) do
    case DeployEx.GitHubActions.find_run_id(branch, sha, workflow_file, retry_max: 1) do
      {:ok, id} -> id
      _ -> nil
    end
  end
```

- [ ] **Step 2: Insert into pipeline after `commit_and_push_rewrites`**

```elixir
  case wait_for_build(qa_node, build_state, opts[:wait_for_build] || false, opts, tui_pid) do
    {:ok, :skipped} -> :ok
    {:ok, _run_id} -> Progress.update_log(tui_pid, "  Build succeeded.")
    {:error, reason} -> handle_build_failure(qa_node, build_state, reason, opts, tui_pid)
  end
```

`handle_build_failure/5` is implemented in the next task.

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: WARN — `handle_build_failure/5` undefined (until next task). Comment out the `{:error, ...}` branch temporarily, OR use `raise "TODO"` — we'll wire it up in Task 16.

For now, replace the error branch with:

```elixir
    {:error, reason} -> raise "build failed: #{inspect(reason)}"
```

Then re-run `mix compile --warnings-as-errors` and verify clean.

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/deploy_ex.qa.create.ex
git commit -m "feat(qa.create): wait for GH Actions build when --wait-for-build"
```

---

## Task 16: Failure prompt + 4-option recovery routing

**Files:**
- Modify: `lib/mix/tasks/deploy_ex.qa.create.ex`

- [ ] **Step 1: Add `handle_build_failure/5` with 4-option prompt**

```elixir
  defp handle_build_failure(qa_node, build_state, %{reason: reason, run_id: run_id}, opts, tui_pid) do
    repo_slug = github_repo_slug()
    workflow_url =
      case {repo_slug, run_id} do
        {slug, id} when is_binary(slug) and is_integer(id) -> "https://github.com/#{slug}/actions/runs/#{id}"
        _ -> "(workflow run URL unavailable)"
      end

    prompt = """
    Build failed (#{inspect(reason)})
    Workflow run: #{workflow_url}

    What would you like to do?
      [1] Destroy QA node + revert (full rollback)
      [2] Leave everything (no cleanup)
      [3] Destroy QA node only (keep commit + local files)
      [4] Revert LLM changes + repush (keep QA node, retry build)
    """

    choice = ask_failure_choice(tui_pid, prompt)
    apply_failure_choice(choice, qa_node, build_state, opts)

    System.halt(1)
  end

  defp github_repo_slug do
    case DeployEx.Utils.run_command_with_return("gh repo view --json nameWithOwner --jq .nameWithOwner", File.cwd!()) do
      {:ok, slug} -> String.trim(slug)
      _ -> nil
    end
  end

  defp ask_failure_choice(tui_pid, prompt) do
    if is_pid(tui_pid) do
      DeployEx.TUI.Progress.confirm(tui_pid, %{prompt: prompt, preview: nil, options: ~w(1 2 3 4)})
    else
      Mix.shell().prompt(prompt) |> String.trim()
    end
  end

  defp apply_failure_choice("1", qa_node, build_state, opts) do
    {action, branch} = build_state.branch_resolution
    backup_dir = DeployEx.QaHostRewrite.backup_dir(qa_node.app_name, qa_node.instance_id)

    DeployEx.QaHostRewrite.restore(backup_dir, opts)

    if action === :create_new do
      DeployEx.GitOperations.delete_remote_branch(File.cwd!(), branch)
    else
      DeployEx.GitOperations.revert_and_push(File.cwd!())
    end

    DeployEx.QaNode.terminate_qa_node(qa_node, opts)
  end

  defp apply_failure_choice("2", _qa_node, _build_state, _opts), do: :ok

  defp apply_failure_choice("3", qa_node, _build_state, opts) do
    DeployEx.QaNode.terminate_qa_node(qa_node, opts)
  end

  defp apply_failure_choice("4", qa_node, _build_state, opts) do
    backup_dir = DeployEx.QaHostRewrite.backup_dir(qa_node.app_name, qa_node.instance_id)
    DeployEx.QaHostRewrite.restore(backup_dir, opts)
    DeployEx.GitOperations.revert_and_push(File.cwd!())
  end
```

- [ ] **Step 2: Replace the temporary `raise` from Task 15**

Find the `{:error, reason} -> raise "build failed: #{inspect(reason)}"` line and change it back to:

```elixir
    {:error, reason} -> handle_build_failure(qa_node, build_state, reason, opts, tui_pid)
```

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/deploy_ex.qa.create.ex
git commit -m "feat(qa.create): add 4-option recovery prompt on build failure"
```

---

## Task 17: Moduledoc update + final verification

**Files:**
- Modify: `lib/mix/tasks/deploy_ex.qa.create.ex` (moduledoc only)

The orchestration layer is glue across already-tested units (Tasks 4–11 cover GitHubActions, Tasks 9–11 cover GitOperations, Task 12 covers CLI parsing). End-to-end coverage is manual (verification step below) — there's no return on writing a brittle integration test that mocks the entire pipeline.

- [ ] **Step 1: Update `@moduledoc`**

Find the existing `@moduledoc` block in `lib/mix/tasks/deploy_ex.qa.create.ex`. Add a `## Wait for build` section after the existing usage examples:

```elixir
  ## Wait for build (CI-gated deploys)

  Pass `--wait-for-build` to commit + push the SSL/host rewrites and wait for
  GitHub Actions to build the release artifact before deploying.

      mix deploy_ex.qa.create cfx_web --public-ip-cert --wait-for-build --tag canary

  Detection: scans `.github/workflows/*.yml` for the workflow whose `on.push.branches`
  matches the QA branch and whose jobs (or sub-workflow jobs) run `mix deploy_ex.release`.

  Branch resolution: if the current branch matches `^qa[\/-]` it is reused; otherwise
  derives `qa/<app>-<tag>` (or `qa/<app>-<short_sha>` if `--tag` is omitted).

  Options:
    --build-workflow=<file>   Override workflow auto-detection
    --build-job=<job_id>      Override job auto-detection within the workflow
    --build-timeout=<minutes> Default 30. Max wait for the build to complete

  On build failure, prompts with 4 options:
    1. Destroy QA node + revert (full rollback)
    2. Leave everything (no cleanup)
    3. Destroy QA node only (keep commit + local files)
    4. Revert LLM changes + repush (keep QA node, retry build)
```

- [ ] **Step 2: Run full test suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 3: Run credo**

Run: `mix credo --strict`
Expected: no findings.

- [ ] **Step 4: Compile clean**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 5: Manual verification (cannot be unit-tested)**

```bash
cd /path/to/cheddar_flow_ex_umbrella
git checkout main      # ensure not already on a qa branch
mix deploy_ex.qa.create cfx_web --public-ip-cert --wait-for-build --tag canary --instance-type t3.small
```

Verify:
- Pre-flight steps (5–8) run BEFORE EC2 provisioning
- Workflow detection picks `pipeline.yml` + `deploy-qa`
- Commit + push to `qa/cfx_web-canary` succeeds
- Polling shows per-job log lines in the TUI
- On build success: deploy proceeds, QA node serves HTTPS via the IP cert
- On forced build failure (e.g., introduce a syntax error): the 4-option prompt renders correctly

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/deploy_ex.qa.create.ex
git commit -m "docs(qa.create): document --wait-for-build flag in moduledoc"
```

---

## Self-Review Checklist

After implementing all 17 tasks:

- [ ] **Spec coverage:** Every section of the spec maps to a task above:
  - Architecture (modules) → Tasks 3–11
  - Pipeline ordering → Tasks 13–16
  - Failure flow → Task 16
  - CLI surface → Task 12
  - Testing → Tasks 3–11 (unit), 17 (integration)
- [ ] **Placeholder scan:** No `TODO`, `TBD`, or "implement later" comments left in code (the temporary `raise "build failed"` in Task 15 is removed in Task 16).
- [ ] **Type consistency:** `find_build_workflow/2` returns `%{file:, job_id:}`. `commit_and_push/5` returns `{:ok, sha}`. `resolve_qa_branch/4` returns `{:reuse_current | :create_new, branch}`. All consumers in `qa.create.ex` match.
- [ ] **Verification gate:** Final `mix test`, `mix credo --strict`, `mix compile --warnings-as-errors` all pass.
- [ ] **Functional verification (manual):** Run `mix deploy_ex.qa.create cfx_web --public-ip-cert --wait-for-build --tag canary` against a test umbrella; verify pipeline reaches the build-wait step, polls correctly, and either deploys on success or routes to the failure prompt.
