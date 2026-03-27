# Configuration Guide

## Application Config

All configuration is accessed via `DeployEx.Config`. Set values in your project's `config/config.exs`:

```elixir
config :deploy_ex,
  aws_region: "us-west-2",
  aws_resource_group: "MyApp Backend",
  aws_release_bucket: "myapp-elixir-deploys-prod",
  deploy_folder: "./deploys"
```

### Config Keys Reference

| Key | Default | Description |
|-----|---------|-------------|
| `aws_region` | `"us-west-2"` | Primary AWS region |
| `aws_log_region` | `"us-west-2"` | Region for log bucket |
| `aws_log_bucket` | `"{project}-backend-logs-{env}"` | S3 bucket for Loki logs |
| `aws_release_bucket` | `"{project}-elixir-deploys-{env}"` | S3 bucket for release artifacts |
| `aws_release_state_bucket` | `"{project}-elixir-release-state-{env}"` | S3 bucket for release tracking state |
| `aws_release_state_lock_table` | `"{project}-terraform-state-lock-{env}"` | DynamoDB table for Terraform state locking |
| `deploy_folder` | `"./deploys"` | Local directory for generated Terraform/Ansible files |
| `aws_resource_group` | `"{ProjectName} Backend"` | AWS resource group tag value |
| `aws_project_name` | `"{project-kebab-case}"` | Project name for AWS resource naming |
| `aws_base_ami_name` | `"debian-13"` | Base AMI name filter |
| `aws_base_ami_architecture` | `"x86_64"` | AMI architecture |
| `aws_base_ami_owner` | `"136693071363"` (Debian official) | AMI owner account |
| `aws_security_group_id` | `nil` | Override security group (otherwise discovered by prefix) |
| `aws_iam_instance_profile` | `nil` | IAM instance profile for EC2 |
| `aws_names_include_env?` | `false` | Include environment in AWS resource names |
| `terraform_backend` | `:s3` | Terraform state backend (`:s3` or `:local`) |
| `terraform_default_args` | `[]` | Default Terraform CLI args per command |
| `tui_enabled` | `true` | Enable terminal UI (auto-disabled in CI) |
| `iac_tool` | `"terraform"` | Infrastructure-as-code tool name |

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `AWS_ACCESS_KEY_ID` | AWS credentials |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials |
| `AWS_PROFILE` | AWS CLI profile name (default: `"default"`) |
| `CI` | Set to `"true"` in CI — configures erlexec for root, disables TUI |
| `DEPLOY_EX_TUI_ENABLED` | Override TUI enabled state (`"true"` / `"false"`) |

### AWS Credential Chain

ExAws resolves credentials in order:
1. Explicit env var (`AWS_ACCESS_KEY_ID`)
2. System environment lookup
3. AWS CLI profile (`~/.aws/credentials`, profile from `AWS_PROFILE`)
4. EC2 instance role

## Redeploy Config

Control which file changes trigger a redeploy per release. Configure in your root `mix.exs`:

```elixir
releases: [
  my_app: [
    applications: [my_app: :permanent],
    deploy_ex: [
      redeploy_config: [
        my_app: [
          whitelist: ["apps/my_app/lib/my_app\\.ex$"],
          # OR
          blacklist: ["apps/my_app/test/.*"]
        ]
      ]
    ]
  ]
]
```

- **whitelist** — only redeploy when matched files change
- **blacklist** — redeploy on any change except matched files

## Terraform Variables

Override Terraform defaults with `--var-file`:

```bash
mix terraform.apply --var-file prod.tfvars
```

Target specific resources:

```bash
mix terraform.apply --target module.aws_instance_my_app
```

Default args can be set per command in config:

```elixir
config :deploy_ex,
  terraform_default_args: [
    apply: [auto_approve: true, var_file: "prod.tfvars"]
  ]
```

## Optional Services

Toggle monitoring and infrastructure services when generating files:

| Flag | Service | Default |
|------|---------|---------|
| `--no-database` | PostgreSQL (RDS) | enabled |
| `--no-redis` | Redis | enabled |
| `--no-grafana` | Grafana UI | enabled |
| `--no-loki` | Grafana Loki (logging) | enabled |
| `--no-prometheus` | Prometheus (metrics) | enabled |
| `--no-sentry` | Sentry (error tracking) | enabled |

Pass these to `mix terraform.build`, `mix ansible.build`, or `mix deploy_ex.full_setup`.

See also: [Deployment Guide](../tutorials/getting_started.md) | [API Reference](../reference/mix_tasks.md)
