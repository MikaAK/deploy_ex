# Configuration Reference

All configuration is accessed through `DeployEx.Config`. Override defaults in your project's `config/config.exs`:

```elixir
config :deploy_ex,
  aws_region: "us-west-2",
  aws_resource_group: "MyApp Backend",
  aws_release_bucket: "myapp-elixir-deploys-prod",
  deploy_folder: "./deploys",
  llm_provider: {LangChain.ChatModels.ChatAnthropic, model: "claude-3-5-sonnet-latest"}
```

## Config Keys

| Key | Default | Purpose |
|-----|---------|---------|
| `aws_region` | `"us-west-2"` | Primary AWS region |
| `aws_log_region` | `"us-west-2"` | Region for log bucket |
| `aws_log_bucket` | `"<project>-backend-logs-<env>"` | Loki/log archive S3 bucket |
| `aws_release_bucket` | `"<project>-elixir-deploys-<env>"` | Release artifact S3 bucket |
| `aws_release_state_bucket` | `"<project>-elixir-release-state-<env>"` | Release tracking + history bucket |
| `aws_terraform_state_lock_table` | `"<project>-terraform-state-lock-<env>"` | DynamoDB table for Terraform state locking (read via `Config.aws_release_state_lock_table/0`) |
| `deploy_folder` | `"./deploys"` | Local directory for rendered Terraform/Ansible files |
| `aws_resource_group` | `"<TitleCase Project> Backend"` | Value of the `Group` tag on every AWS resource |
| `aws_project_name` | kebab-case project name | Used in resource naming |
| `aws_iam_instance_profile` | `nil` | Override IAM instance profile (otherwise auto-discovered) |
| `aws_base_ami_name` | `"debian-13"` | Base AMI name filter |
| `aws_base_ami_architecture` | `"x86_64"` | Base AMI architecture (`x86_64` or `arm64`) |
| `aws_base_ami_owner` | `"136693071363"` (Debian) | AMI owner account ID |
| `aws_security_group_id` | `nil` | Override security group (otherwise discovered by prefix) |
| `aws_names_include_env` | `false` | Include env suffix in resource names |
| `terraform_backend` | `:s3` | `:s3` or `:local` |
| `terraform_default_args` | `[]` | Per-command default CLI args (see below) |
| `iac_tool` | `"terraform"` | Tool name (use `"tofu"` for OpenTofu) |
| `tui_enabled` | `true` | Enable TUI (auto-disabled outside TTYs) |
| `llm_provider` | `nil` | Required for `--ai-review` / `--llm-merge` / `--public-ip-cert`. `{module, opts}` tuple consumed by LangChain |
| `env` | `to_string(Mix.env())` | Environment name used in defaults |

The kebab-case project name is derived from your top-level Mix project. `<env>` defaults to `Mix.env()` (`prod` / `dev` / `test`). Unless you set `aws_names_include_env: true`, the env suffix is folded into the bucket names but not the resource group label.

## Computed Paths

| Function | Returns |
|----------|---------|
| `DeployEx.Config.terraform_folder_path/0` | `<deploy_folder>/terraform` |
| `DeployEx.Config.ansible_folder_path/0` | `<deploy_folder>/ansible` |

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `AWS_ACCESS_KEY_ID` | AWS credentials |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials |
| `AWS_PROFILE` | AWS CLI profile (default `"default"`) |
| `CI` | When `"true"`, configures erlexec for root and disables the TUI |
| `DEPLOY_EX_TUI_ENABLED` | `"true"` / `"false"` override for `tui_enabled` |

### AWS Credential Chain

ExAws resolves credentials in this order:
1. Explicit env vars (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)
2. System environment lookup
3. AWS CLI profile (`~/.aws/credentials` matched against `AWS_PROFILE`)
4. EC2 instance role

## Redeploy Config

Control which file changes trigger a release rebuild. Add to your root `mix.exs`:

```elixir
releases: [
  my_app: [
    applications: [my_app: :permanent],
    deploy_ex: [
      redeploy_config: [
        my_app: [
          whitelist: ["apps/my_app/lib/my_app\\.ex$"]
          # OR
          # blacklist: ["apps/my_app/test/.*"]
        ]
      ]
    ]
  ]
]
```

- **whitelist** — only redeploy when matching files change
- **blacklist** — redeploy on any change *except* matching files

## Terraform Defaults

Pin per-command defaults so you don't repeat them every invocation:

```elixir
config :deploy_ex,
  terraform_default_args: [
    apply: [auto_approve: true, var_file: "prod.tfvars"],
    plan: [var_file: "prod.tfvars"]
  ]
```

The keys are matched as regexes against the command name, so `:apply` matches both `terraform.apply` and `apply`. Args become `--auto-approve --var-file prod.tfvars` on the wire.

You can still override per call:

```bash
mix terraform.apply --var-file staging.tfvars
mix terraform.plan --target module.aws_instance_my_app
```

## Optional Services

`mix terraform.build`, `mix ansible.build`, and `mix deploy_ex.full_setup` accept these toggle flags:

| Flag | Disables |
|------|----------|
| `--no-database` | RDS Postgres (terraform only) |
| `--no-redis` | Redis + Redis Stack (terraform only) |
| `--no-grafana` | Grafana UI |
| `--no-loki` | Grafana Loki + Alloy log shipping |
| `--no-prometheus` | Prometheus + node_exporter |
| `--no-sentry` | Sentry |
| `--no-logging` | All log shipping (Loki + Alloy) |

## Universal Options

Most tasks accept these:

| Option | Purpose |
|--------|---------|
| `--aws-region` | Override AWS region |
| `--aws-bucket` / `--aws-release-bucket` | Override release bucket |
| `--resource-group` | AWS `Group` tag for filtering instances (default: `<ProjectName> Backend`) |
| `--only` / `--except` | Repeatable filters by app name (release/ansible tasks) |
| `--force` / `-f` | Skip confirmation prompts |
| `--quiet` / `-q` | Suppress non-error output |
| `--no-tui` | Disable the ExRatatui UI |

## Switching IaC Tools (OpenTofu)

Set `:iac_tool` to swap Terraform for [OpenTofu](https://opentofu.org/) (or any drop-in replacement):

```elixir
config :deploy_ex, iac_tool: "tofu"
```

The value is the binary name on `$PATH`. Every `terraform.*` task delegates through `DeployEx.Utils` to this binary, so `terraform.apply` becomes `tofu apply`, etc.

## GitHub Actions Secrets

When you run `mix deploy_ex.install_github_action`, the workflow expects three secrets:

| Secret | Purpose |
|--------|---------|
| `DEPLOY_EX_AWS_ACCESS_KEY_ID` | AWS access key for the deploy role |
| `DEPLOY_EX_AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `EC2_PEM_FILE` | Contents of the SSH PEM file generated by `mix deploy_ex.full_setup` |

Any additional secret prefixed with `__DEPLOY_EX__` is auto-injected as an env var with the prefix stripped. For example, `__DEPLOY_EX__DATABASE_URL` becomes `DATABASE_URL` in the build environment, available during `mix compile`.

The workflow re-runs `mix terraform.build` and `mix ansible.build` on every push to keep generated files in sync with `mix.exs` releases. If you've heavily customised those files, remove the build steps from the workflow.

Change detection runs against git history — a deploy only redeploys an app when:
1. Code changed in the app
2. Code changed in a related umbrella dep (umbrella only)
3. `mix.lock` dependency changed
4. The release isn't already in S3

> **Note:** GitHub branch protections can block the auto-commit step in the workflow. To work with protections enabled, modify the generated workflow to use a PAT or app token with bypass permissions.

See also: [Mix Tasks Reference](mix_tasks.md) | [Architecture](../explanation/architecture.md) | [Terraform Variables](terraform_variables.md)
