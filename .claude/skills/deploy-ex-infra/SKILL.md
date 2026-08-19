---
name: deploy-ex-infra
description: "Use this skill whenever the user wants to run terraform/tofu or ansible commands for cloud infrastructure (AWS or OCI). Covers: terraform plan, apply, build, init, drop, replace, refresh, state fixes; provider selection (--provider aws|oci, cloud_provider config); ansible setup and ansible build; database dump and restore; EBS snapshot create or delete; state bucket and lock table management; deploy_ex configuration changes; GitHub Actions CI/CD workflow installation; tearing down or destroying environments; generating PEM keys; setting up new project infrastructure from scratch; regenerating .tf files after adding releases. Do NOT use for: deploying releases with ansible.deploy, SSH access to servers, building release artifacts, or editing deploy_ex library source code."
---

# deploy_ex Infrastructure Management

Guide for managing AWS infrastructure through deploy_ex's Terraform and Ansible integration.

## Terraform Operations

### Generate Configuration Files

```bash
mix terraform.build [options]
```

Renders EEx templates from `priv/terraform/` into `./deploys/terraform/`. Generated files include: `variables.tf`, `ec2.tf`, `database.tf`, `providers.tf`, `key-pair-main.tf`, `outputs.tf`, plus static files (`bucket.tf`, `network.tf`, `iam.tf`) and modules.

Cloud provider: `--provider aws|oci` (or `config :deploy_ex, cloud_provider: :oci`). Only the active provider's template set is seeded into `./deploys/terraform/` (OCI templates live in `priv/terraform/providers/oci/`); the sync runs on every build so static files stay current.

Options to disable services:
- `--no-database` — skip RDS
- `--no-redis` — skip Redis
- `--no-grafana` — skip Grafana UI
- `--no-loki` — skip Grafana Loki logging
- `--no-logging` — skip logging stack
- `--no-prometheus` — skip Prometheus metrics
- `--no-sentry` — skip Sentry error tracking

Opt-in nodes:
- `--clickhouse` — add a ClickHouse node
- `--rabbitmq` — add a RabbitMQ node

Other: `--env`, `--aws-region`, `--directory`, `--render-dir`, `--pem-app-name`, `--db-password`

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

Options: `-a` auto-pull AWS credentials from `~/.aws/credentials`, `-h` host-only (skip playbooks), `-n` new-only (skip existing playbooks), `--provider aws|oci`

OCI provider flags: `--oci-compartment-id`, `--oci-profile`, `--oci-region`, `--oci-namespace`, `--oci-release-bucket`

### Server Setup and Deployment

```bash
mix ansible.ping                          # test connectivity
mix ansible.setup [--only app1] [--parallel]  # initial server configuration
mix ansible.deploy [--only app1] [--parallel] [-t sha]  # deploy
mix ansible.rollback my_app [--select]    # rollback to previous release
```

Setup installs: BEAM tuning, log rotation, pip3, awscli (oci_cli on OCI), IPv6, Prometheus exporter, Grafana Alloy log shipping, save_ami (AWS only).

Deploy pulls release from S3 and restarts the systemd service.

### Ansible Roles (in priv/ansible/roles/)

| Role | Purpose |
|------|---------|
| `deploy_node` | Main application deployment |
| `grafana_ui` | Grafana dashboard |
| `grafana_loki` / `grafana_alloy` | Log aggregation (Alloy ships logs to Loki) |
| `prometheus_db` / `prometheus_exporter` | Metrics collection |
| `redis_server` | Redis node |
| `rabbitmq_server` | RabbitMQ node (opt-in via `terraform.build --rabbitmq`) |
| `clickhouse` | ClickHouse node (opt-in via `terraform.build --clickhouse`) |
| `letsencrypt` | SSL certificates |
| `beam_linux_tuning` | BEAM VM optimization |
| `elixir_runner` | Elixir runtime for script hosts |
| `save_ami` | Snapshot instance to AMI (QA node reuse) |
| `awscli` | AWS CLI installation |
| `log_cleanup` | Log rotation |
| `ipv6` | IPv6 configuration |
| `chromedriver` / `chromedriver_setup` / `ffmpeg` / `pip3` | Utility installs |

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

Multi-cloud: `cloud_provider: :aws | :oci` (default `:aws`), `iac_tool: "terraform" | "tofu"`, and OCI settings under `config :deploy_ex, :oci, [...]` (compartment id, region, namespace, release bucket) — read per-key via `DeployEx.Config.oci_setting/1`.

For full config reference, read `guides/reference/configuration.md`.

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

For the full deployment walkthrough, read `guides/how-to/deploying_releases.md`; infra management detail in `guides/how-to/managing_infrastructure.md`.
