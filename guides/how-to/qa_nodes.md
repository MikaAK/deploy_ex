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

## CI-Gated Deploys (`--wait-for-build`)

For end-to-end QA flows where the release tarball is built by GitHub Actions (not locally), pass `--wait-for-build`. deploy_ex commits and pushes the SSL/host rewrites to a QA branch, finds the release workflow, and blocks until the build completes.

```bash
mix deploy_ex.qa.create my_app --public-ip-cert --wait-for-build --tag canary
```

**Workflow detection:** scans `.github/workflows/*.yml` for the workflow whose `on.push.branches` glob matches the QA branch and whose jobs (or sub-workflow jobs) run `mix deploy_ex.release`.

**Branch resolution:**
- Current branch matches `^qa[\/-]` → reuse it
- Otherwise → derive `qa/<app>-<tag>` (or `qa/<app>-<short_sha>` if `--tag` is omitted)

**Override flags:**
- `--build-workflow=<file>` — bypass auto-detection
- `--build-job=<job_id>` — narrow to one job inside the workflow
- `--build-timeout=<minutes>` — wait cap (default `30`)

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

Most tasks accept `--qa` (or `--include-qa`) to target QA hosts:

- `mix ansible.deploy --qa --target-sha auto`
- `mix ansible.setup --include-qa`
- `mix deploy_ex.ssh my_app --qa`
- `mix deploy_ex.instance.health --qa`
- `mix deploy_ex.load_balancer.health --qa`

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [QA pipeline architecture](../explanation/architecture.md#qa-pipeline)
