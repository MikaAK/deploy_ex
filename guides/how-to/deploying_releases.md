# How to Deploy Releases

## Build, Upload, Deploy

```bash
mix deploy_ex.release [--only app1] [--force]    # build changed apps
mix deploy_ex.upload [--parallel 4]               # upload to S3
mix ansible.deploy [--only app1]                  # deploy to instances
```

Change detection compares git SHAs, `mix.lock` diffs, and `mix deps.tree` output. Use `--force` (alias `-f`) to rebuild every app, or `--recompile` (`-r`) to force recompilation before release.

`--only` and `--except` are repeatable on both `release` and `ansible.deploy`:

```bash
mix deploy_ex.release --only app1 --only app2 --except app3
```

## Deploy a Specific SHA

```bash
mix ansible.deploy --target-sha abc1234           # explicit SHA
mix ansible.deploy --target-sha auto              # newest prod release on current branch
mix ansible.deploy --qa --target-sha auto         # newest QA release on current branch
mix ansible.deploy --qa                           # interactive picker across QA releases
```

The QA picker uses `DeployEx.ReleaseLookup` and filters releases to SHAs reachable from the current git branch (best-effort — falls back to all QA releases if git lookup fails).

## Rollback

```bash
mix ansible.rollback                              # roll back to previous release
mix ansible.rollback --select                     # interactive picker from history
mix ansible.rollback --only app1
```

Release history is tracked in S3 at `release-state/<prefix>/<app>/release_history.txt`.

## Upload Flags

| Flag | Purpose |
|------|---------|
| `--parallel N` | Concurrent uploads (default 4) |
| `--qa` | Mark as a QA release (alternative to `qa/` branch detection) |
| `--aws-region` | Override `:aws_region` config |
| `--aws-bucket` | Override release bucket |
| `--force` / `-f` | Re-upload even if a matching SHA already exists |

QA releases land under the `qa/` prefix in the release bucket and are tracked separately so prod deploys never see them.

## GitHub Actions CI/CD

```bash
mix deploy_ex.install_github_action
```

Two workflows are installed:

- **`deploy-ex-release.yml`** — builds with `mix deploy_ex.release`, uploads with `mix deploy_ex.upload`, then runs `mix ansible.deploy` with the freshly built SHA. Adds `--qa` automatically when the branch matches `qa/*`.
- **`setup-new-nodes.yml`** — runs every 15 minutes and on-demand; finds instances missing the `SetupComplete` tag and runs `mix ansible.setup --only <app>` for each app with unconfigured nodes.

### Secrets convention

Any GitHub Actions secret prefixed with `__DEPLOY_EX__` is converted by `github-action-secrets-to-env.sh` into an env var without the prefix and exported to the deployment shell. For example:

```
__DEPLOY_EX__DATABASE_URL  →  DATABASE_URL
__DEPLOY_EX__SECRET_KEY    →  SECRET_KEY
```

Use `--copy-json-env-file` on `mix ansible.deploy` to also copy a JSON env file into the host environment.

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Configuration](../reference/configuration.md)
