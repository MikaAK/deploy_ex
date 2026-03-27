# Getting Started with deploy_ex

This tutorial walks you through setting up deploy_ex from scratch and deploying your first release.

## Prerequisites

- **Terraform** — infrastructure provisioning
- **Ansible** — server configuration (installed automatically via pip3 if missing)
- **Git** — version control (required for change detection)
- **AWS credentials** — configured via env vars, AWS CLI profile, or instance role

## Step 1: Install

Add deploy_ex to your `mix.exs` deps:

```elixir
{:deploy_ex, "~> 0.1"}
```

```bash
mix deps.get
```

deploy_ex works with both **umbrella** and **single-app** Elixir projects.

## Step 2: Full Setup

```bash
mix deploy_ex.full_setup -yak
```

The flags: `-y` auto-approve Terraform, `-a` auto-pull AWS credentials from `~/.aws/credentials`, `-k` skip-deploy (useful for first run).

This runs through:

1. `terraform.create_state_bucket` — S3 bucket for Terraform state
2. `terraform.create_state_lock_table` — DynamoDB table for state locking
3. `terraform.build` — generate `.tf` files from templates
4. `terraform.apply` — provision AWS infrastructure (EC2, RDS, S3, VPC)
5. `terraform.refresh` — sync Terraform state
6. `ansible.build` — generate Ansible playbooks and config
7. Wait 10 seconds for instances to initialize
8. `ansible.ping` — verify connectivity
9. `ansible.setup` — configure servers (packages, systemd, logging)
10. `deploy_ex.upload` — upload release artifacts to S3
11. `ansible.deploy` — deploy application to instances

## Step 3: Install CI/CD

```bash
mix deploy_ex.install_github_action
git add . && git commit -m "chore: add deployment"
```

## Step 4: Your First Release

```bash
mix deploy_ex.release     # build (detects changed apps)
mix deploy_ex.upload       # upload to S3
mix ansible.deploy         # deploy to EC2 instances
```

deploy_ex intelligently detects which apps changed since the last release by comparing git SHAs, mix.lock diffs, and dependency trees. Only changed apps get rebuilt.

For Phoenix apps, the asset pipeline (npm, esbuild, sass, tailwind, phx.digest) runs automatically.

## Next Steps

- [How to Deploy Releases](../how-to/deploying_releases.md) — rollback, target specific apps, CI/CD
- [How to Use QA Nodes](../how-to/qa_nodes.md) — ephemeral test instances
- [Configuration Reference](../reference/configuration.md) — all config keys and env vars
- [Mix Tasks Reference](../reference/mix_tasks.md) — all 73 commands
