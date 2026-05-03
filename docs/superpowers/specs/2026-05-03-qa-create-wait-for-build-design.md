# `qa.create --wait-for-build` design

Add a `--wait-for-build` flag to `mix deploy_ex.qa.create` that:
1. Commits the SSL/host rewrites that the pipeline already produces locally.
2. Pushes them to a QA branch (auto-derived or current).
3. Waits for the GitHub Actions workflow that builds the release artifact (auto-detected by scanning for jobs that run `mix deploy_ex.release`) to complete.
4. On success, replaces `qa_node.target_sha` with the freshly-built commit's SHA so Ansible deploys the artifact we just built.
5. On failure, prompts the user with a 4-option recovery menu (full rollback / leave / destroy node only / revert + repush).

## Architecture

### New module: `DeployEx.GitHubActions`

```
lib/deploy_ex/github_actions.ex
```

Public API:
- `find_build_workflow(repo_root, qa_branch)` → `{:ok, %{file: String.t(), job_id: String.t()}} | {:error, ErrorMessage.t()}`
  - Scans `.github/workflows/*.yml`.
  - Picks the workflow whose `on.push.branches` glob-matches `qa_branch`.
  - Among matching workflows, selects the one with a job whose steps include `mix deploy_ex.release` — either as a literal `run:` string OR via a `uses: ./.github/workflows/<sub>.yml` whose own job runs the command.
  - Returns `:ambiguous` (caller prompts) when 2+ candidates match.
  - Returns `:not_found` with the list of scanned workflow files when no match.
- `find_run_id(branch, sha, workflow_file)` → `{:ok, run_id} | {:error, ErrorMessage.t()}`
  - Shells out to `gh run list --branch=<branch> --commit=<sha> --workflow=<file> --json status,conclusion,databaseId,name --limit 1`.
  - Retries every 5s for up to 60s while no run is found (run takes a few seconds to register after push).
- `wait_for_run(run_id, target_job, opts)` → `{:ok, run} | {:error, :build_failed | :timeout | ErrorMessage.t()}`
  - Polls `gh run view <id> --json status,conclusion,jobs` every 15s, max 30 min (`opts[:timeout_minutes]`).
  - Tracks the target job AND its `needs:` dependencies; returns `:build_failed` early if any dep finishes with conclusion `[failure, cancelled, skipped]`.
  - Emits per-poll log line back to caller (via `opts[:log_fn]`).
- `ensure_installed()` → `:ok | {:error, ErrorMessage.t()}`
  - `gh --version` shell check.
  - On miss: prints message and runs `Mix.shell().yes?("Install gh via Homebrew?")` (or apt on Linux). On confirm, shells out to `brew install gh` (or `sudo apt install gh`).
- `ensure_authenticated()` → `:ok | {:error, ErrorMessage.t()}`
  - `gh auth status` shell check; error message includes `gh auth login` hint.

### New module: `DeployEx.GitOperations`

```
lib/deploy_ex/git_operations.ex
```

Public API:
- `resolve_qa_branch(repo_root, app_name, tag, sha)` → `{:reuse_current, branch} | {:create_new, branch}`
  - Reads current branch via `git rev-parse --abbrev-ref HEAD`.
  - If matches `~r/^qa[\/-]/`: `{:reuse_current, current_branch}`.
  - Else: `{:create_new, derive_qa_branch_name(app_name, tag, sha)}` where the derived name is `qa/<app>-<tag>` if `tag` is non-nil, else `qa/<app>-<short_sha>` (first 7 chars of `sha`).
- `commit_and_push(repo_root, branch, files, opts)` → `{:ok, new_sha} | {:error, ErrorMessage.t()}`
  - If `opts[:create_new?]`: `git checkout -B <branch>` (optionally `<base_sha>` if `opts[:base_sha]`).
  - `git add <files...>` — stages exactly the files listed, NOT `git add -A`.
  - `git commit -m "qa: rewrite host config for <app> (<short_sha>)"` (no `--amend`, no footers per global CLAUDE.md).
  - Push: `--force-with-lease` for `:create_new?` branches, regular `git push -u origin <branch>` for first push, regular `git push` for reused branches.
  - Returns the resulting commit's SHA via `git rev-parse HEAD`.
- `revert_and_push(repo_root, branch)` → `{:ok, _} | {:error, ErrorMessage.t()}`
  - `git revert HEAD --no-edit && git push`.
- `delete_remote_branch(repo_root, branch)` → `:ok | {:error, ErrorMessage.t()}`
  - `git push origin --delete <branch>`.

### Touched: `Mix.Tasks.DeployEx.Qa.Create`

Pipeline gains 5 new steps when `--wait-for-build` is present (12 → 18 steps total). `@pipeline_total_steps` becomes a function of opts.

### Touched: `DeployEx.QaHostRewrite.apply_proposals/4`

Already returns the list of written file paths via the manifest. Caller passes that list to `DeployEx.GitOperations.commit_and_push/4`.

## Pipeline ordering (with --wait-for-build)

```
 1. validate app
 2. validate SHA (default HEAD if --wait-for-build)
 3. plan host rewrite (LLM with __qa_public_ip__ placeholder)
 4. confirm target files (Progress.confirm/2 prompts user)
 5. NEW: ensure gh installed
 6. NEW: validate gh auth
 7. NEW: detect build workflow + job (scan .github/workflows/*.yml)
 8. NEW: resolve qa branch + verify clean working tree
 9. gather infra
10. create node (provisions EC2, gets instance_id + public_ip)
11. wait instance
12. save state to S3
13. apply host rewrite (substitute placeholder → real public_ip → write files)
14. NEW: commit + push qa branch
15. NEW: wait for build workflow
       on success: qa_node = %{qa_node | target_sha: new_sha}; save state again
       on failure: 4-option prompt (see "Failure flow")
16. wait SSH
17. setup & deploy (Ansible pulls artifact for new_sha)
18. attach LB
```

Steps 5–8 run BEFORE EC2 provisioning so a misconfigured workflow / dirty tree / missing `gh` fails fast (no AWS spend).

## Failure flow

When step 15 detects a failed build (target job conclusion in `[failure, cancelled, skipped]` OR a `needs:` dep failed), the TUI flips into confirm-mode (existing `Progress.confirm/2` infra) and shows:

```
Build failed
  Workflow run: https://github.com/<owner>/<repo>/actions/runs/<id>
  Failed job:   <job_name>  (target job <skipped|failed>)

What would you like to do?
  [1] Destroy QA node + revert (full rollback)
  [2] Leave everything (no cleanup)
  [3] Destroy QA node only (keep commit + local files)
  [4] Revert LLM changes + repush (keep QA node, retry build)
```

### Action matrix

| Step | Option 1 | Option 2 | Option 3 | Option 4 |
|---|---|---|---|---|
| Restore local files (`QaHostRewrite.restore`) | ✓ | ✗ | ✗ | ✓ |
| Branch we created → delete remote | ✓ | ✗ | ✗ | n/a |
| Branch we created → revert + push | n/a | ✗ | ✗ | ✓ |
| User's existing branch → revert + push | ✓ | ✗ | ✗ | ✓ |
| Terminate EC2 instance | ✓ | ✗ | ✓ | ✗ |
| Exit code | nonzero | nonzero | nonzero | nonzero |

Option 4's revert+repush is the same operation regardless of whether we created the branch (always `git revert HEAD && git push`). After option 4, the user can re-run `qa.create` against the (now reverted) branch — the build retries with the rewrites undone.

### Success path display

While waiting, the log pane shows one-line per-poll status updates:
```
mix-compile-prod: in_progress (4m 15s)
mix-compile-prod: success (5m 30s)
deploy-qa: queued
deploy-qa: in_progress (1m 02s)
deploy-qa: success (8m 47s)
```

Gauge stays at "step 15 / 18 = 83%" until the target job completes, then advances to step 16.

## CLI surface

```
--wait-for-build              boolean   Commit/push qa branch and wait for GH
                                        Actions to build before deploying.
--build-workflow=<file>       string    Override workflow auto-detection.
                                        Path relative to .github/workflows/.
--build-job=<job_id>          string    Override job auto-detection.
--build-timeout=<minutes>     integer   Default 30. Max wait for the build.
```

### Compatibility / precedence

- Independent of `--public-ip-cert`. The flag is meaningful on its own (e.g., QA-test current branch's local config without public-IP cert). When both are used, the LLM rewrite step still runs and the rewritten files are committed.
- `--sha` allowed alongside `--wait-for-build`: if given, `git checkout -B <qa-branch> <sha>` to base the qa branch off that SHA. Default: `HEAD`.
- Working tree must be clean (existing `QaHostRewrite.working_tree_clean?/1`) before step 5.
- If on a branch matching `^qa[\/-]` AND `--sha` given AND `--sha !== HEAD`, error: `"already on qa branch <branch>; --sha conflicts with current HEAD. Either drop --sha or checkout a different branch first."`

### Updated `@moduledoc` example

```
mix deploy_ex.qa.create cfx_web --public-ip-cert --wait-for-build --tag canary
```

## Testing

### `test/deploy_ex/github_actions_test.exs`

- `find_build_workflow/2`
  - picks `pipeline.yml` when its job calls `mix deploy_ex.release`
  - resolves `uses: ./.github/workflows/deploy.yml` and inspects sub-workflow's run steps
  - matches branch pattern via glob (`qa/**` matches `qa/cfx_web-canary`)
  - returns `:ambiguous` when 2+ workflows match
  - returns `:not_found` with helpful error when no workflow runs `deploy_ex.release`
- `find_run_id/3`
  - returns the run_id matching SHA + branch (mocked gh)
  - retries up to 60s when run hasn't appeared yet
  - `{:error, :not_found}` after retry budget exhausted
- `wait_for_run/3`
  - `{:ok, run}` on conclusion=success
  - `{:error, :build_failed}` on conclusion=failure
  - aborts early when a `needs:` dep fails (target job will skip)
  - `{:error, :timeout}` after build-timeout exceeded
- `ensure_installed/0`
  - `:ok` when `gh --version` succeeds
  - prompts and runs `brew install gh` on macOS confirm (mocked shell)
  - `{:error, _}` on user decline
- `ensure_authenticated/0`
  - `:ok` when `gh auth status` succeeds
  - `{:error, _}` with helpful message otherwise

### `test/deploy_ex/git_operations_test.exs`

- `resolve_qa_branch/4`
  - `{:reuse_current, "qa-experimental"}` when on a qa-* branch
  - `{:reuse_current, "qa/foo"}` when on a qa/* branch
  - `{:create_new, "qa/cfx_web-canary"}` when not on qa branch + tag given
  - `{:create_new, "qa/cfx_web-abc1234"}` when not on qa branch + no tag (short_sha)
- `commit_and_push/4`
  - stages only the listed files (not all dirty files)
  - `--force-with-lease` for newly-created branches
  - regular `push -u` for first push of created branch
  - regular `push` for reused branches
  - returns `{:ok, new_sha}` containing the resulting commit's SHA
- `revert_and_push/2`
  - runs `git revert HEAD --no-edit` then `git push`
- `delete_remote_branch/2`
  - runs `git push origin --delete <branch>`

### `test/mix/tasks/deploy_ex.qa.create_test.exs` (extend)

- `--wait-for-build` errors cleanly when on-qa-branch + `--sha != HEAD`
- steps 5–8 run BEFORE `create_node` (fail-fast — assert ordering via test logger)
- failure prompt routes to correct rollback action per options 1–4
- on success, `qa_node.target_sha` is replaced with the new commit's SHA before Ansible runs

### Test fixtures

```
test/support/fixtures/workflows/
├── cfx_pipeline.yml          # copy of cfx umbrella's pipeline.yml (sanitized)
├── deploy.yml                # sub-workflow with mix deploy_ex.release
├── no_deploy.yml             # negative case: no deploy_ex.release
├── ambiguous_a.yml           # both run deploy_ex.release
└── ambiguous_b.yml
```

### Mock pattern

Inject a `gh` shim through opts (`opts[:gh] = &MyMock.run/1`), defaulting to `DeployEx.Utils.run_command_with_return/2`. Matches the existing test plumbing pattern in deploy_ex — no new mocking library.

## Out of scope

- Multi-app QA nodes (one app per pipeline run, as today).
- Reading from forks (always pushes to `origin`).
- Watching multiple parallel build runs (one workflow run per qa branch push).
- Caching `gh` install path detection across runs (re-checks each run; cheap).
