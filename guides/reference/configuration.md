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

## GitHub Actions Setup

`mix deploy_ex.install_github_action` writes two workflows under `.github/workflows/`:

- **`deploy-ex-release.yml`** — runs on push to `main` (and `qa/*` for QA releases). Pipeline: `mix.compile` (with `__DEPLOY_EX__*` env vars injected) → `mix deploy_ex.ssh.authorize` → `mix deploy_ex.release` → `mix deploy_ex.upload` → `mix ansible.deploy --target-sha <sha>` → `mix deploy_ex.ssh.authorize -r`.
- **`setup-new-nodes.yml`** — runs every 15 minutes (and on push). Detects instances missing `SetupComplete=true` and runs `ansible.setup --only <app>` for any app with unconfigured nodes.

After installing, three things must be configured on the GitHub side.

### 1. Repository secrets

Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value |
|--------|-------|
| `DEPLOY_EX_AWS_ACCESS_KEY_ID` | AWS access key for the deploy IAM user |
| `DEPLOY_EX_AWS_SECRET_ACCESS_KEY` | matching secret key |
| `EC2_PEM_FILE` | full contents of `deploys/terraform/*.pem` (generated by `full_setup`). The workflow writes this to disk on every run for ansible. |

Plus any **runtime app env vars** prefixed `__DEPLOY_EX__`. Example:

| Secret name | Becomes env var |
|---|---|
| `__DEPLOY_EX__DATABASE_URL` | `DATABASE_URL` |
| `__DEPLOY_EX__SECRET_KEY` | `SECRET_KEY` |
| `__DEPLOY_EX__SENTRY_DSN` | `SENTRY_DSN` |

The `github-action-secrets-to-env.sh` helper that ships in `.github/` strips the prefix and exports the values to the build shell so they're available during `mix compile` and on deployed instances.

### 2. Workflow permissions

Go to **Settings → Actions → General → Workflow permissions** and select **"Read and write permissions"**. Required because the workflow's `github-action-maybe-commit-terraform-changes.sh` step pushes back any drift in `deploys/` (e.g. when `terraform.build` adds a new app entry).

### 3. Branch protection (if enabled)

Branch protections on `main` block the auto-commit step. Two options:

- **Disable protection on `main`** — simplest, fine for solo / small teams
- **Use a PAT or GitHub App token** with bypass permissions; replace the default `${{ secrets.GITHUB_TOKEN }}` references in the workflow with your token. Document this in your team's runbook so the token is rotated when its owner leaves.

### Change detection

CI's deploy step only ships apps that actually changed. The deciders (in order):

1. Code change in the app's directory (`apps/<app>/` for umbrella, `lib/` / `test/` / `priv/` for single-app)
2. Code change in a related umbrella dep
3. `mix.lock` dependency change
4. Release missing from S3

`--force` overrides this — useful for cutting a clean release after a rollback.

### What the workflow does NOT do by default

The generated workflow has these steps **commented out** at the top:

```yaml
# - name: Run Terraform Build & Apply
#   run: mix terraform.build --force && mix terraform.apply --auto-approve
# - name: Run Ansible Build
#   run: mix ansible.build --force --new-only
# - name: Maybe Github Update
#   run: ./.github/github-action-maybe-commit-terraform-changes.sh
```

Uncomment them if you want CI to run `terraform.apply` and `ansible.build` on every push. Most teams leave them off and run those locally on schema changes — running them on every push means CI has full AWS provisioning rights, which is a security tradeoff.

See also: [Mix Tasks Reference](mix_tasks.md) | [Architecture](../explanation/architecture.md) | [Terraform Variables](terraform_variables.md)
