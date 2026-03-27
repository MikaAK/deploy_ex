---
name: deploy-ex-infra
description: "Use when managing AWS infrastructure through deploy_ex's Terraform and Ansible integration — provisioning EC2/RDS/S3, generating Terraform files, running terraform plan/apply, building Ansible playbooks, setting up servers, database dump/restore, EBS snapshots, Terraform state management, or configuring deploy_ex for a project. Triggers on: terraform, ansible, infrastructure, provision, database dump, database restore, EBS snapshot, state bucket, generate terraform files, configure deploy_ex, setup infrastructure. Use this even when the user says 'terraform' or 'ansible' without mentioning deploy_ex — if they're in a deploy_ex project, this skill has the correct commands."
---

# deploy_ex Infrastructure Management

Guide for managing AWS infrastructure through deploy_ex's Terraform and Ansible integration.

## Terraform Operations

### Generate Configuration Files

```bash
mix terraform.build [options]
```

Renders EEx templates from `priv/terraform/` into `./deploys/terraform/`. Generated files include: `variables.tf`, `ec2.tf`, `database.tf`, `providers.tf`, `key-pair-main.tf`, `outputs.tf`, plus static files (`bucket.tf`, `network.tf`, `iam.tf`) and modules.

Options to disable services:
- `--no-database` — skip RDS
- `--no-redis` — skip Redis
- `--no-grafana` — skip Grafana UI
- `--no-loki` — skip Grafana Loki logging
- `--no-prometheus` — skip Prometheus metrics
- `--no-sentry` — skip Sentry error tracking

Other: `--env`, `--aws-region`, `--aws-bucket`, `--aws-log-bucket`

### Plan and Apply

```bash
mix terraform.plan [--var-file prod.tfvars] [--target module.aws_instance_my_app]
mix terraform.apply [-y] [--var-file prod.tfvars] [--target ...]
```

`-y` auto-approves. `--target` can be repeated to scope to specific resources.

### Other Terraform Commands

```bash
mix terraform.init [-u]               # initialize (upgrade providers with -u)
mix terraform.refresh                   # sync state with actual AWS
mix terraform.output [-s]              # show outputs (-s for JSON)
mix terraform.replace -n my_app [--all] [-y]  # replace EC2 instances
mix terraform.drop [-y]                # destroy all infrastructure
```

### State Management

```bash
mix terraform.create_state_bucket       # S3 bucket for remote state
mix terraform.create_state_lock_table   # DynamoDB for state locking
mix terraform.drop_state_bucket
mix terraform.drop_state_lock_table
mix terraform.generate_pem [--backend s3|local] [--output-file path]
mix terraform.show_password [--backend s3|local]
```

State backend configured via `config :deploy_ex, terraform_backend: :s3` (default) or `:local`.

### EBS Snapshots

```bash
mix terraform.create_ebs_snapshot my_app [--description "pre-deploy"] [--include-root]
mix terraform.delete_ebs_snapshot [--all] [--max-age-days 30]
```

### Database Operations

Dump and restore RDS databases via SSH tunnel through jump server:

```bash
# Dump (custom format recommended for parallel restore)
mix terraform.dump_database --format custom --output backup.pgdump

# Dump as SQL text
mix terraform.dump_database --format text --output backup.sql

# Restore to RDS
mix terraform.restore_database backup.pgdump --jobs 4

# Restore locally
mix terraform.restore_database backup.pgdump --local

# Schema only
mix terraform.dump_database --schema-only
mix terraform.restore_database backup.pgdump --schema-only

# Show database password
mix terraform.show_password
```

Auto-detects format: `.pgdump` → `pg_restore`, `.sql` → `psql`.

## Ansible Operations

### Generate Configuration

```bash
mix ansible.build [options]
```

Generates from `priv/ansible/` templates:
- `ansible.cfg` — with PEM file path
- `aws_ec2.yaml` — dynamic EC2 inventory
- `group_vars/all.yaml` — global variables
- `playbooks/{app}.yaml` — per-app deploy playbooks
- `setup/{app}.yaml` — per-app setup playbooks

Options: `-a` auto-pull AWS credentials from `~/.aws/credentials`, `-h` host-only (skip playbooks), `-n` new-only (skip existing playbooks)

### Server Setup and Deployment

```bash
mix ansible.ping                          # test connectivity
mix ansible.setup [--only app1] [--parallel]  # initial server configuration
mix ansible.deploy [--only app1] [--parallel] [-t sha]  # deploy
mix ansible.rollback my_app [--select]    # rollback to previous release
```

Setup installs: system packages, awscli, BEAM tuning, log rotation, S3 crash dumps, systemd service.

Deploy pulls release from S3 and restarts the systemd service.

### Ansible Roles (in priv/ansible/roles/)

| Role | Purpose |
|------|---------|
| `deploy_node` | Main application deployment |
| `grafana_ui` | Grafana dashboard |
| `grafana_loki` / `grafana_loki_promtail` | Log aggregation |
| `prometheus_db` / `prometheus_exporter` | Metrics collection |
| `letsencrypt` | SSL certificates |
| `beam_linux_tuning` | BEAM VM optimization |
| `awscli` | AWS CLI installation |
| `log_cleanup` | Log rotation |
| `ipv6` | IPv6 configuration |

## Configuration

Set in your project's `config/config.exs`:

```elixir
config :deploy_ex,
  aws_region: "us-west-2",
  aws_resource_group: "MyApp Backend",
  aws_release_bucket: "myapp-elixir-deploys-prod",
  deploy_folder: "./deploys",
  terraform_backend: :s3,
  terraform_default_args: [
    apply: [auto_approve: true, var_file: "prod.tfvars"]
  ]
```

Key config: `aws_region`, `aws_release_bucket`, `deploy_folder` ("./deploys"), `terraform_backend` (`:s3` or `:local`), `aws_base_ami_name` ("debian-13").

For full config reference, read `docs/configuration-guide.md`.

## Template Customization

Generated files in `./deploys/` are user-owned after generation. deploy_ex tracks modifications via SHA256 manifest for upgrades:

```bash
mix deploy_ex.export_priv     # export templates to ./deploys/
mix deploy_ex.upgrade_priv    # sync upstream changes (respects user mods)
```

`upgrade_priv` behavior:
- **New files** → copied automatically
- **Unmodified files** (hash matches base) → overwritten silently
- **Modified files** (user changed) → backup + overwrite + diff shown
- **Optional** `--llm-merge` → AI-assisted 3-way merge for conflicts

## AWS Resource Naming

deploy_ex tags all resources with:
- `Group` — from `Config.aws_resource_group()` (e.g. "MyApp Backend")
- `Environment` — from `Config.env()`
- `ManagedBy` — always `"DeployEx"`

Instance discovery uses `InstanceGroup` tags. Check `Config.aws_names_include_env?()` when building resource name prefixes.

## GitHub Actions

```bash
mix deploy_ex.install_github_action
```

Generates CI/CD workflows. Secrets prefixed with `__DEPLOY_EX__` are automatically injected as environment variables during deployment.

For the full deployment walkthrough, read `docs/deployment-guide.md`.
