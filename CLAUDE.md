# deploy_ex

Elixir library that provisions cloud infrastructure (Terraform/OpenTofu + Ansible) and deploys Elixir releases onto it. AWS is the primary provider; OCI is in progress behind the `DeployEx.Cloud` provider seam. Plain Mix library, NOT an umbrella — run everything from the repo root. The apps it deploys live in consumer projects; `./deploys/` output exists only in those projects, not here.

@Agents.md

Per-directory `Agents.md` files add scoped agreements (lib/, lib/mix/tasks/, priv/terraform/, priv/ansible/, test/) — read the one for the directory you're changing.

## Commands

```bash
mix test                                  # full suite, from repo root
mix test test/deploy_ex/foo_test.exs:42   # single test
mix compile --warnings-as-errors          # warnings are errors
```

No credo or dialyzer in this repo's deps — the gates are tests + clean compile.

## Skills — load the matching one before working

| Task | Skill |
|------|-------|
| Editing lib/, adding Mix tasks, templates, tests | `deploy-ex-dev` |
| Generating/applying terraform + ansible, state, config | `deploy-ex-infra` |
| Deploying, QA nodes, SSH, autoscale, load tests | `deploy-ex-ops` |
| Anything Oracle Cloud (`--provider oci`, oci CLI, OCIDs) | `deploy-ex-oci` |
| Diagnosing a broken deploy/instance/service | `deploy-ex-debug` |
| `./deploys` customization, export/upgrade_priv, manifest, drift | `deploy-ex-priv-templates` |

`skills/` at the repo root is symlinks into `.claude/skills/` — add both when creating a skill.

## Docs

- `guides/` — Diataxis layout: `tutorials/`, `how-to/`, `reference/`, `explanation/`. Update the matching guide when behavior changes.
- `README.md` — user-facing CLI reference; keep flags in sync with task changes.

## Testing notes

- No mocking libraries — dependency injection (`:run_fn` / `:request_fn` seams, module params)
- `async: true`; never `Application.put_env/3` in tests
- Parser fixtures under `test/deploy_ex/release_uploader/update_validator/`
