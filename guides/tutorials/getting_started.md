# Getting Started with deploy_ex

This tutorial walks you through setting up deploy_ex from scratch and deploying your first release.

## Prerequisites

- **Terraform** (or **OpenTofu**) — infrastructure provisioning. deploy_ex auto-installs on supported platforms (macOS / Debian / Alpine / Amazon Linux).
- **Ansible** — server configuration. Auto-installed via pip3 if missing.
- **Git** — required for change detection.
- **AWS credentials** — env vars, AWS CLI profile, or instance role.
- **`gh` CLI** — only needed if you use `--wait-for-build` on `mix deploy_ex.qa.create`. Auto-installed when invoked.

## Step 1: Install

Add deploy_ex to your `mix.exs` deps:

```elixir
{:deploy_ex, "~> 0.1"}
```

```bash
mix deps.get
```

deploy_ex works with both umbrella and single-app Elixir projects. Single-app projects synthesise a release entry from `:app` if you don't define one explicitly.

> **Important:** every release in your `mix.exs` must end its `steps:` list with `:tar`. deploy_ex looks for the resulting `.tar.gz` artifacts in `_build/<env>/rel/<app>/`.

## Step 2: Full Setup

```bash
mix deploy_ex.full_setup -yak
```

The flags:
- `-y` — auto-approve Terraform plans
- `-a` — auto-pull AWS credentials from `~/.aws/credentials` into Ansible group_vars
- `-k` — skip the final deploy step (`--skip-deploy`)
- `-p` — skip the wait/setup phase (`--skip-setup`)

This pipeline runs:

1. `terraform.create_state_bucket` — S3 bucket for Terraform state
2. `terraform.create_state_lock_table` — DynamoDB table for state locking
3. `terraform.build` — generate `.tf` files from EEx templates
4. `terraform.apply` — provision AWS infrastructure (VPC, EC2, RDS, ALB)
5. `terraform.refresh` — sync Terraform state with AWS
6. `ansible.build` — generate Ansible inventory and playbooks
7. 10 second wait for instances to initialize
8. `ansible.ping` — verify connectivity
9. `ansible.setup` — bootstrap servers (BEAM tuning, monitoring agents, app user)
10. `deploy_ex.upload` — upload release artifacts to S3
11. `ansible.deploy` — deploy application

## Step 3: Install CI/CD

```bash
mix deploy_ex.install_github_action
git add .github && git commit -m "chore: add deployment"
```

This generates two workflows in `.github/workflows/`:

- **`deploy-ex-release.yml`** — main deploy pipeline (build, upload, ansible.deploy)
- **`setup-new-nodes.yml`** — periodic check for instances missing the `SetupComplete` tag, runs `ansible.setup` for each app that has unconfigured nodes

It also drops two helper scripts into `.github/`:

- **`github-action-secrets-to-env.sh`** — converts `__DEPLOY_EX__`-prefixed secrets to env vars
- **`github-action-maybe-commit-terraform-changes.sh`** — auto-commits Terraform changes from CI

## Step 4: Migration Scripts

```bash
mix deploy_ex.install_migration_script
```

Generates a single `rel/overlays/bin/migrate.sh` per repo. Mix copies overlays into every release tarball, so on the server the same script lives at `/srv/<release>/bin/migrate.sh`:

```bash
/srv/my_app/bin/migrate.sh migrate
/srv/my_app/bin/migrate.sh rollback 20240101120000
```

The script discovers its release name from its own filesystem location and only runs migrations for apps actually packaged in that release — apps it can't load are skipped silently.

## Step 5: Your First Release

```bash
mix deploy_ex.release            # build (detects changed apps)
mix deploy_ex.upload              # upload to S3
mix ansible.deploy                # deploy to EC2 instances
```

deploy_ex detects which apps changed since the last release by:

- Diffing git SHAs (`current_sha..last_sha`)
- Parsing `mix.lock` diffs (dependency version changes)
- Walking `mix deps.tree` (transitive local-app changes)

Only changed apps get rebuilt. For Phoenix apps, `mix assets.deploy` (esbuild, sass, tailwind, phx.digest) runs automatically when assets are detected.

## Step 6: Customise (Optional)

After the initial run, your `./deploys/` directory contains the **rendered** Terraform and Ansible. To take ownership of those templates and start customising:

```bash
mix deploy_ex.export_priv         # write rendered templates + a SHA256 manifest
```

You now own `./deploys/`. When you upgrade the deploy_ex dep later, sync upstream changes back into your customised files:

```bash
mix deploy_ex.upgrade_priv               # interactive per-hunk review
mix deploy_ex.upgrade_priv --ai-review   # LLM proposes per-file accept/reject
mix deploy_ex.upgrade_priv --llm-merge   # autonomous LLM merge (with backup)
```

See [Managing Infrastructure](../how-to/managing_infrastructure.md) for the full priv-upgrade workflow.

## Next Steps

- [How to Deploy Releases](../how-to/deploying_releases.md) — rollback, target specific apps, CI/CD
- [How to Use QA Nodes](../how-to/qa_nodes.md) — ephemeral test instances + `--wait-for-build`
- [How to Manage Infrastructure](../how-to/managing_infrastructure.md) — terraform, priv upgrades, EBS snapshots
- [Configuration Reference](../reference/configuration.md) — all config keys and env vars
- [Mix Tasks Reference](../reference/mix_tasks.md) — every command with its switches
