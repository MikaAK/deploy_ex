# Deployment Guide

## Prerequisites

- **Terraform** — infrastructure provisioning
- **Ansible** — server configuration and deployment (installed automatically via pip3 if missing)
- **Git** — version control (required for change detection)
- **AWS credentials** — configured via env vars, AWS CLI profile, or instance role

## Initial Setup

The quickest path from zero to deployed:

```bash
# 1. Add deploy_ex to deps
vi mix.exs  # Add {:deploy_ex, "~> 0.1"}
mix deps.get

# 2. Full setup (generates files, provisions infrastructure, deploys)
mix deploy_ex.full_setup -yak

# 3. Install CI/CD
mix deploy_ex.install_github_action
git add . && git commit -m "chore: add deployment"
```

The `-yak` flags: `-y` auto-approve Terraform, `-a` auto-pull AWS credentials, `-k` skip-deploy (useful for first run).

### What `full_setup` Does

1. `terraform.create_state_bucket` — S3 bucket for Terraform state
2. `terraform.create_state_lock_table` — DynamoDB table for state locking
3. `terraform.build` — generate `.tf` files from templates
4. `terraform.apply` — provision AWS infrastructure
5. `terraform.refresh` — sync Terraform state
6. `ansible.build` — generate Ansible playbooks and config
7. Wait 10 seconds for instances to initialize
8. `ansible.ping` — verify connectivity
9. `ansible.setup` — configure servers (packages, systemd, logging)
10. `deploy_ex.upload` — upload release artifacts to S3
11. `ansible.deploy` — deploy application to instances

## Release Workflow

### Build Releases

```bash
mix deploy_ex.release
```

This intelligently detects which apps have changed since the last release by:
- Running `git diff` between current SHA and last uploaded SHA
- Parsing `mix.lock` for dependency changes
- Checking the `mix deps.tree` for transitive dependency impacts

For Phoenix apps, it automatically runs the asset pipeline (npm install, esbuild, sass, tailwind, phx.digest).

Options: `--force` rebuilds all, `--only app1 --only app2` targets specific apps, `--except app3` excludes apps.

### Upload to S3

```bash
mix deploy_ex.upload
```

Uploads built `.tar.gz` artifacts to the release bucket. Supports `--parallel` for concurrent uploads (max 4).

QA releases are auto-detected from branch name (`qa/*` or `qa-*` prefixes).

### Deploy to Instances

```bash
mix ansible.deploy
```

Runs Ansible playbooks against EC2 instances. Supports `--only`/`--except` filtering.

For deploying a specific SHA: `mix ansible.deploy --target-sha abc1234`

### Rollback

```bash
mix ansible.rollback my_app
mix ansible.rollback my_app --select  # interactive history picker
```

Fetches the 25 most recent releases from S3 and deploys the previous (or selected) SHA.

## GitHub Actions

```bash
mix deploy_ex.install_github_action
```

Generates CI/CD workflows using the `__DEPLOY_EX__` secret prefix convention. Secrets prefixed with `__DEPLOY_EX__` are automatically injected as environment variables during deployment.

## QA Nodes

Ephemeral EC2 instances for testing specific release SHAs:

```bash
# Create QA node with specific SHA
mix deploy_ex.qa.create my_app --sha abc1234

# Deploy different SHA to existing QA node
mix deploy_ex.qa.deploy my_app --sha def5678

# Attach to load balancer for traffic testing
mix deploy_ex.qa.attach_lb my_app

# Clean up
mix deploy_ex.qa.detach_lb my_app
mix deploy_ex.qa.destroy my_app
```

QA nodes use app-specific AMIs when available (skips Ansible setup). State is persisted to S3.

## Load Testing

k6-based load testing with dedicated EC2 runner instances:

```bash
mix deploy_ex.load_test.init my_app          # scaffold test scripts
mix deploy_ex.load_test.create_instance      # provision k6 runner
mix deploy_ex.load_test.upload               # SCP scripts to runner
mix deploy_ex.load_test.exec --target-url http://... # run tests
mix deploy_ex.load_test.destroy_instance     # clean up
```

Metrics are pushed to Prometheus via k6's remote write integration.

## Autoscaling

### Refresh Strategies

```bash
# Rolling refresh (default) — launch new, then terminate old
mix deploy_ex.autoscale.refresh my_app

# Replace root volume — in-place update
mix deploy_ex.autoscale.refresh my_app --strategy ReplaceRootVolume
```

Availability presets:
- `--availability launch-first` — 100% min, 110% max (zero-downtime)
- `--availability terminate-first` — 90% min, 100% max (cost-saving)

### Scaling

```bash
mix deploy_ex.autoscale.scale my_app --desired 3
mix deploy_ex.autoscale.status my_app
```

## Database Operations

Dump and restore via SSH tunnel through jump server:

```bash
# Dump (custom format for parallel restore)
mix terraform.dump_database --format custom --output backup.pgdump

# Restore to RDS
mix terraform.restore_database backup.pgdump --jobs 4

# Restore locally
mix terraform.restore_database backup.pgdump --local
```

## Infrastructure Updates

Generated files in `./deploys/` are user-owned. To update after changing config:

```bash
mix terraform.build    # regenerate .tf files (preserves customizations via variable injection)
mix terraform.plan     # review changes
mix terraform.apply    # apply
mix ansible.build      # regenerate playbooks
```

### Template Upgrades

When updating deploy_ex, sync template changes:

```bash
mix deploy_ex.upgrade_priv
```

Uses SHA256 manifest tracking: unmodified files are overwritten silently, user-modified files get a backup + diff. Optional `--llm-merge` for AI-assisted 3-way merges.

## Connecting to Nodes

```bash
mix deploy_ex.ssh my_app                    # interactive SSH
mix deploy_ex.ssh my_app --root             # SSH as root
mix deploy_ex.ssh my_app --log              # stream app logs
mix deploy_ex.ssh my_app --iex              # remote IEx console
mix deploy_ex.ssh.authorize my_app          # add SSH key
```

See also: [API Reference](api-reference.md) | [Configuration Guide](configuration-guide.md)
