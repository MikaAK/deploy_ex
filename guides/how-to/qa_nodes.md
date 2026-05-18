# How to Use QA Nodes

Ephemeral EC2 instances for testing specific release SHAs in isolation. State is persisted to S3 (`qa-nodes/<app>/<instance_id>.json`) and EC2 tags so multiple developers can see the same fleet.

## Create a QA Node

```bash
mix deploy_ex.qa.create my_app                                      # prompt for QA SHA on current branch
mix deploy_ex.qa.create my_app --sha abc1234
mix deploy_ex.qa.create my_app --sha abc1234 --tag canary
mix deploy_ex.qa.create my_app --sha abc1234 --instance-type t3.medium
mix deploy_ex.qa.create my_app --sha abc1234 --attach-lb            # attach to load balancer after deploy
mix deploy_ex.qa.create my_app --sha abc1234 --use-ami              # boot from app's pre-baked AMI (skips ansible.setup)
mix deploy_ex.qa.create my_app --sha abc1234 --skip-setup --skip-deploy  # provision only
```

Default instance type is `t3.small`. The QA node boots from the base AMI (Debian) and runs `ansible.setup` fresh — pass `--use-ami` to reuse the per-app AMI snapshot.

## Public-IP TLS Certificate

Use `--public-ip-cert` for standalone QA nodes that aren't behind a load balancer:

```bash
mix deploy_ex.qa.create my_app --sha abc1234 --public-ip-cert --tag canary
```

This issues a Let's Encrypt cert via the HTTP-01 challenge and triggers an **LLM-assisted rewrite** of host config in your umbrella so the node serves traffic from its public IP. Originals are backed up under `~/.deploy_ex/qa-host-rewrites/<app>-<instance_id>/` and restored automatically by `qa.destroy`.

Requirements:
- An LLM provider configured at `:deploy_ex, :llm_provider` (see `DeployEx.Config.llm_provider/0`)
- A clean working tree (the rewrite needs to commit changes)

Pass `--skip-host-rewrite` to keep the existing config unchanged.

## CI-Gated Deploys (default)

`mix deploy_ex.qa.create` defaults to a CI-gated flow: it commits + pushes the SSL/host rewrites to a QA branch, finds the matching release workflow, and blocks until the build completes before deploying. Pass `--use-local-build` to opt out and use a locally-built release instead.

```bash
mix deploy_ex.qa.create my_app --public-ip-cert --tag canary       # CI build (default)
mix deploy_ex.qa.create my_app --use-local-build --tag canary      # local build
```

While running in the default flow, qa.create also idempotently patches the detected workflow yml to add a `Deploy to QA Node` step that runs `mix deploy_ex.qa.deploy --git-branch <branch>` on QA refs, and guards the existing `Run Ansible Deploy` step so it skips on QA branches. Patches are marked with sentinel comments and committed to the QA branch alongside the host rewrites. Pass `--skip-action-install` to opt out of just the workflow patch.

**Workflow detection:** scans `.github/workflows/*.yml` for the workflow whose `on.push.branches` glob matches the QA branch and whose jobs (or sub-workflow jobs) run `mix deploy_ex.release`. Hard-errors with a hint to pass `--use-local-build` if none match.

**Branch resolution:**
- Current branch matches `^qa[\/-]` → reuse it
- Otherwise → derive `qa/<app>-<tag>` (or `qa/<app>-<short_sha>` if `--tag` is omitted)

**Override flags:**
- `--use-local-build` — opt out of CI build, deploy a locally-built release
- `--build-workflow=<file>` — bypass auto-detection
- `--build-job=<job_id>` — narrow to one job inside the workflow
- `--build-timeout=<minutes>` — wait cap (default `30`)
- `--skip-action-install` — keep the workflow yml untouched (don't install the QA-deploy step)

**On build failure** the task prompts you to choose:
1. Destroy QA node + revert (full rollback)
2. Leave everything (no cleanup, manual intervention)
3. Destroy QA node only (keep commit + local files)
4. Revert LLM changes + repush (keep QA node, retry build)

## Deploy a Different SHA to an Existing Node

```bash
mix deploy_ex.qa.deploy my_app --sha def5678
mix deploy_ex.qa.deploy my_app --sha def5678 --instance-id i-0abc123
mix deploy_ex.qa.deploy my_app --sha def5678 --public-ip-cert        # toggle cert on
mix deploy_ex.qa.deploy my_app --sha def5678 --no-public-ip-cert     # toggle cert off
```

The cert toggle updates the `UsePublicIpCert` EC2 tag and the S3 state, so Ansible picks up the new mode on this run and every subsequent deploy. Omit the flag entirely to leave the current mode unchanged.

## Manage Load Balancer Attachment

```bash
mix deploy_ex.qa.attach_lb my_app                  # auto-discover target groups
mix deploy_ex.qa.attach_lb my_app --instance-id i-0abc123 --port 4000 --wait
mix deploy_ex.qa.detach_lb my_app
mix deploy_ex.qa.detach_lb my_app --target-group <arn>
```

`--wait` blocks for up to 5 minutes for the target to pass health checks.

## List, Destroy, Clean Up

```bash
mix deploy_ex.qa.list                              # every app
mix deploy_ex.qa.list --app my_app
mix deploy_ex.qa.list --json

mix deploy_ex.qa.destroy                           # interactive picker across all apps
mix deploy_ex.qa.destroy my_app                    # picker for my_app
mix deploy_ex.qa.destroy my_app --instance-id i-0abc123
mix deploy_ex.qa.destroy --all --force             # destroy every QA node, no prompt

mix deploy_ex.qa.cleanup                           # remove orphans (S3 state without instance, or instance without state)
mix deploy_ex.qa.cleanup --dry-run
mix deploy_ex.qa.cleanup --force
```

Destroying a QA node also detaches it from any load balancer and restores the host config backup created by `--public-ip-cert`.

## Targeting QA Nodes from Other Tasks

Two flags control whether QA nodes are included:

| Flag | Behaviour |
|------|-----------|
| `--qa` | Target **only** QA nodes (excludes prod) |
| `--include-qa` | Include QA nodes **alongside** prod |

Examples:

```bash
mix ansible.deploy --only my_app --qa                # deploy to QA only
mix ansible.deploy --only my_app --include-qa        # prod + QA together
mix ansible.deploy --qa --target-sha auto            # newest QA release on current branch
mix ansible.setup --only my_app --include-qa
mix deploy_ex.ssh my_app --qa
mix deploy_ex.instance.health --qa
mix deploy_ex.load_balancer.health --qa
```

QA releases are stored under `qa/<app>/` in the release bucket and tracked at `release-state/qa/<app>/` — prod tooling ignores them automatically.

## QA Node Tags

Every QA node carries:

| Tag | Value |
|-----|-------|
| `Name` | `<app>-qa-<short_sha>-<timestamp>` (or `<app>-qa-<tag>` if `--tag` was used) |
| `Group` | Same as production (used by libcluster) |
| `InstanceGroup` | `<app>` — used by Ansible playbook targeting |
| `QaNode` | `true` — used by `--qa` / `--include-qa` filters |
| `TargetSha` | Full git SHA |
| `InstanceTag` | Custom label from `--tag` (if provided) |
| `UsePublicIpCert` | `true` / `false` — drives the `--public-ip-cert` mode |
| `ManagedBy` | `DeployEx` |
| `SetupComplete` | `true` after `ansible.setup` finishes |

## How QA Nodes Work

**State.** Persisted to S3 at `qa-nodes/<app>/<instance_id>.json` and mirrored on EC2 tags. Multiple QA nodes per app are supported — operations always verify state against AWS before acting.

**Infrastructure discovery.** QA nodes reuse the production security group, subnet, and IAM profile. AMI is auto-discovered: first the per-app AMI tagged with `App` + `Environment` + `ManagedBy: DeployEx`, then the base Debian AMI. No Terraform state dependency — the QA pipeline calls AWS APIs directly.

**Cloud-init bootstrap.** User-data deploys the `--sha` automatically on first boot, so `--skip-deploy` is rarely needed.

**Load balancer attachment.** Optional — useful for canary testing or A/B deploys. Health checks behave identically to prod targets.

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [QA pipeline architecture](../explanation/architecture.md#qa-pipeline) | [Troubleshooting](troubleshooting.md)
