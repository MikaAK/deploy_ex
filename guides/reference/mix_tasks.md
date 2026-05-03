# Mix Tasks Reference

Complete catalog of all 68 Mix tasks. Run `mix help <task>` for the full moduledoc, or `mix deploy_ex` to launch an interactive wizard that exposes the same surface.

**Conventions:**
- `--only` and `--except` accept multiple invocations and filter by app name.
- `--qa` typically *restricts* to QA hosts; `--include-qa` *adds* QA hosts to the prod set.
- `--no-tui` disables the ExRatatui UI on tasks that use it.
- `--force` / `-f` skips confirmation prompts; `--quiet` / `-q` suppresses non-error output.

## Quick Reference

| Task | Description |
|------|-------------|
| `mix deploy_ex` | Interactive TUI wizard for every command |
| `mix deploy_ex.full_setup` | Bootstrap infra + deploy in one shot |
| `mix deploy_ex.full_drop` | Tear everything down (infra + ./deploys + workflows + state bucket) |
| `mix deploy_ex.release` | Build releases for changed apps |
| `mix deploy_ex.upload` | Upload releases to S3 |
| `mix deploy_ex.export_priv` | Render templates into `./deploys/` for user customisation |
| `mix deploy_ex.upgrade_priv` | Merge upstream priv changes into `./deploys/` |
| `mix deploy_ex.install_github_action` | Install CI/CD workflows |
| `mix deploy_ex.install_migration_script` | Generate the single `migrate.sh` overlay |
| `mix terraform.*` | Provision / inspect / tear down AWS infra |
| `mix ansible.*` | Build / setup / deploy / rollback / ping |
| `mix deploy_ex.qa.*` | QA node lifecycle |
| `mix deploy_ex.autoscale.*` | ASG capacity + instance refresh |
| `mix deploy_ex.load_test.*` | k6 load test runners |
| `mix deploy_ex.ssh*` | SSH access + IP whitelist |
| `mix deploy_ex.instance.*` / `find_nodes` / `select_node` | Inventory and health |
| `mix deploy_ex.{start,stop,restart}_app`, `restart_machine`, `remake` | App lifecycle |
| `mix deploy_ex.grafana.install_dashboard` | Install Grafana dashboards |

## Setup & Lifecycle

### `mix deploy_ex`
Interactive TUI wizard listing every task with search + form-based input.
- `--no-tui` — fall back to console help text.

### `mix deploy_ex.full_setup`
Run `terraform.create_state_bucket → create_state_lock_table → build → apply → refresh → ansible.build → wait → ping → setup` in sequence. Stops after `ansible.setup` — releases are deployed by CI or by running `mix deploy_ex.release && mix deploy_ex.upload && mix ansible.deploy` separately.
- `-y` / `--auto-approve` — auto-approve Terraform plans (forwarded to terraform.apply)
- `-a` / `--auto-pull-aws` — pull AWS credentials from `~/.aws/credentials` into Ansible group_vars
- `-p` / `--skip-setup` — skip the wait + ansible.setup steps
- `--no-tui` — disable progress UI

### `mix deploy_ex.full_drop`
Destroy all infra and remove deploy_ex artifacts. Calls `terraform.drop`, deletes `./deploys/`, removes `.github/workflows/deploy-ex-release.yml` + helper scripts, and drops the state bucket and lock table. **Destructive, no flags.**

### `mix deploy_ex.install_github_action`
Generate `.github/workflows/deploy-ex-release.yml` and `.github/workflows/setup-new-nodes.yml` plus helper shell scripts.
- `-d, --pem-directory` — terraform dir holding the PEM (default `./deploys/terraform`)
- `-p, --pem` — explicit PEM filename
- `-f, --force` — overwrite existing files
- `-q, --quiet`

### `mix deploy_ex.install_migration_script`
Render a single `rel/overlays/bin/migrate.sh` for the repo. Mix copies overlays into every release tarball, so the same script lands at `/srv/<release>/bin/migrate.sh` on each server. The script derives its release name from its own filesystem location, loads every umbrella app it can (skipping apps not bundled in the current release), and runs `Ecto.Migrator.with_repo/3` for every `:ecto_repos` it finds. Accepts `migrate` (default) or `rollback <VERSION>`.
- `-d, --directory` — output dir (default `rel/overlays/bin`)
- `-f, --force` — overwrite
- `-q, --quiet`

### `mix deploy_ex.export_priv`
Render priv EEx templates with the project's config and copy to `./deploys/`. Writes `.deploy_ex_manifest.exs` (sha256 per file, deploy_ex version) so `upgrade_priv` can later detect user modifications.
- `-f, --force` — overwrite existing files
- `-q, --quiet`

### `mix deploy_ex.upgrade_priv`
Sync upstream priv changes into your customised `./deploys/`. Three modes:

- (default) **Interactive** — category summary + per-hunk DiffViewer
- `--ai-review` — LLM proposes accept/reject per file; you confirm
- `--llm-merge` — LLM applies all changes autonomously (creates timestamped backup)

Both LLM modes require `:deploy_ex, :llm_provider` configured.

## Terraform

| Task | Switches |
|------|----------|
| `mix terraform.init` | `-d directory`, `-u upgrade` |
| `mix terraform.build` | `-d directory`, `-f force`, `-q quiet`, `-v verbose`, `--aws-region`, `--env`, `--no-database`, `--no-loki`, `--no-grafana`, `--no-redis`, `--no-prometheus`, `--no-sentry`, `--no-logging` |
| `mix terraform.plan` | `-d directory`, `-f force`, `-q quiet` (forwards remaining args to `terraform plan`, e.g. `--var-file`, `--target`) |
| `mix terraform.apply` | `-d directory`, `-y auto-approve`, `-f force`, `-q quiet` (forwards `--var-file`, `--target`) |
| `mix terraform.refresh` | `-d directory`, `-f force`, `-q quiet` |
| `mix terraform.output` | `-d directory`, `-s short` (JSON output) |
| `mix terraform.replace` | `-n node` (integer count), `-s string` (substring match), `--all`, `-d directory`, `-y auto-approve`, `--resource-group`, `--region` |
| `mix terraform.drop` | `-d directory`, `-y auto-approve`, `-f force`, `-q quiet` |
| `mix terraform.generate_pem` | `-d directory`, `-o output-file`, `-b backend`, `--bucket`, `--region` |
| `mix terraform.show_password` | `-d directory`, `-q quiet`, `-b backend`, `--bucket`, `--region` |
| `mix terraform.create_state_bucket` | (no switches; uses `:aws_region`) |
| `mix terraform.create_state_lock_table` | (no switches) |
| `mix terraform.drop_state_bucket` | (no switches) |
| `mix terraform.drop_state_lock_table` | (no switches) |
| `mix terraform.create_ebs_snapshot <app>` | `--description`, `--include-root`, `--aws-region`, `--resource-group` |
| `mix terraform.delete_ebs_snapshot [app]` | `--snapshot-ids` (comma-separated), `--all`, `-f force`, `--max-age-days` (integer), `--aws-region`, `--resource-group` |
| `mix terraform.dump_database` | `-d directory`, `-o output`, `-s schema-only`, `-p local-port`, `-i identifier`, `-f format` (custom\|text), `--pem`, `-b backend`, `--bucket`, `--region`, `--resource-group` |
| `mix terraform.restore_database <file>` | `-d directory`, `-l local`, `-s schema-only`, `-p local-port`, `--clean`, `--jobs <n>`, `--pem`, `-b backend`, `--bucket`, `--state-region`, `--resource-group` |

## Ansible

| Task | Switches |
|------|----------|
| `mix ansible.build` | `-d directory`, `-f force`, `-q quiet`, `-a auto-pull-aws`, `-h host-only`, `-n new-only`, `--terraform-directory`, `--aws-release-bucket`, `--no-database` (n/a here), `--no-loki`, `--no-grafana`, `--no-prometheus`, `--no-sentry`, `--no-logging` |
| `mix ansible.setup` | `-d directory`, `-f force`, `-q quiet`, `--only`, `--except`, `--parallel <n>`, `--include-qa`, `--no-tui` |
| `mix ansible.deploy` | `-d directory`, `-l only-local-release`, `-t target-sha` (`auto` resolves newest SHA on branch), `--only`, `--except`, `--copy-json-env-file`, `--parallel <n>`, `--include-qa`, `--qa`, `--no-tui`, `-q quiet` |
| `mix ansible.ping` | `-d directory` |
| `mix ansible.rollback` | `-d directory`, `-s select` (interactive picker), `-f force`, `-q quiet` |

`mix ansible.deploy --target-sha auto` picks the newest prod release on the current branch (or QA release if `--qa` is set). With `--qa` and no `--target-sha`, you get an interactive QA release picker.

## Release Management

| Task | Switches |
|------|----------|
| `mix deploy_ex.release` | `-f force`, `-q quiet`, `-r recompile`, `--only`, `--except`, `--all`, `--aws-region`, `--aws-release-bucket` |
| `mix deploy_ex.upload` | `-f force`, `-q quiet`, `--qa`, `--parallel <n>` (default 4), `--aws-region`, `--aws-release-bucket` |
| `mix deploy_ex.list_app_release_history <app>` | `-l limit`, `-r region`, `-b bucket` |
| `mix deploy_ex.list_available_releases` | `-a app` |
| `mix deploy_ex.view_current_release <app>` | `-r region`, `-b bucket` |
| `mix deploy_ex.remake <node>` | `--no-deploy`, `--no-tui` (chains `terraform.replace → wait → ansible.setup → ansible.deploy`) |

## App Lifecycle

| Task | Switches |
|------|----------|
| `mix deploy_ex.start_app [app]` | `-d directory`, `-p pem`, `-f force`, `-q quiet`, `--resource-group`, `--no-tui` |
| `mix deploy_ex.stop_app [app]` | (same as start_app) |
| `mix deploy_ex.restart_app [app]` | (same as start_app) |
| `mix deploy_ex.restart_machine [app]` | `--aws-region`, `--resource-group`, `-f force`, `-q quiet`, `--no-tui` |
| `mix deploy_ex.download_file [app]` | `-d directory`, `-p pem`, `-f force`, `-q quiet`, `--resource-group` |

## Instances & Inventory

| Task | Switches |
|------|----------|
| `mix deploy_ex.find_nodes` | `-t tag` (repeatable, `KEY=VALUE`), `--setup-complete`, `--setup-incomplete`, `-f format` (table\|json\|ids), `-r region`, `--resource-group`, `-q quiet` |
| `mix deploy_ex.select_node [app]` | `-s short`, `--qa`, `-r region`, `--resource-group` |
| `mix deploy_ex.instance.status` | `-e environment` |
| `mix deploy_ex.instance.health` | `-q qa` (yes — `q` aliases `qa`), `-a all` |
| `mix deploy_ex.load_balancer.health [app]` | `--qa`, `-w watch` (live dashboard), `--json`, `-q quiet`, `--no-tui` |

## SSH

### `mix deploy_ex.ssh [app]`
Picker-based SSH with log/IEx modes.
- `-d directory` — terraform dir holding the PEM (default `./deploys/terraform`)
- `-p, --pem` — explicit PEM file
- `-i index` — pick the nth instance
- `-s short` — print the ssh command instead of running it
- `--instance-id <id>` — target a specific instance (repeatable)
- `--qa` — restrict picker to QA nodes
- `-l, --list` — list candidates and exit
- `--root` — connect as root (`sudo -i`)
- `--log` — `journalctl -u <app>` follow mode
- `-n, --log-count <n>` / `--all` / `--log-user <user>`
- `--iex` — `bin/<app> remote` to attach to the running BEAM
- `--resource-group`, `-f force`, `-q quiet`

### `mix deploy_ex.ssh.authorize`
Manage IP ingress on the security group.
- `-r, --remove` — remove instead of add
- `--ip <addr>` — explicit IP (default = current public IP)
- `--region`
- `--security-group-id <id>` — bypass auto-discovery
- `-f force`, `-q quiet`

## QA Nodes

### `mix deploy_ex.qa <app>`
Overview / quick start (no flags).

### `mix deploy_ex.qa.create <app>`
- `-s, --sha` — target SHA (prompts if omitted)
- `-t, --tag` — instance label (replaces short SHA in name)
- `--instance-type` (default `t3.small`)
- `--skip-setup`, `--skip-deploy`, `--skip-ami`, `--skip-host-rewrite`
- `--use-ami` — boot from app AMI
- `--attach-lb` — register with load balancer after deploy
- `--public-ip-cert` — Let's Encrypt cert + LLM-assisted host rewrite
- `--wait-for-build` — commit + push QA branch, wait for GitHub Actions
- `--build-workflow <file>` / `--build-job <id>` / `--build-timeout <minutes>` (default 30)
- `-f force`, `-q quiet`, `--no-tui`
- `--aws-region`, `--aws-release-bucket`

### `mix deploy_ex.qa.deploy <app>`
- `-s, --sha` (required outside TUI mode)
- `-i, --instance-id` — pick a specific QA node
- `--public-ip-cert` / `--no-public-ip-cert` — toggle cert mode (persisted to state)
- `-q quiet`, `--aws-region`, `--aws-release-bucket`

### `mix deploy_ex.qa.destroy [app]`
- `-i, --instance-id` — destroy a specific instance
- `--all` — destroy every QA node across every app
- `-f force`, `-q quiet`

### `mix deploy_ex.qa.list`
- `-a, --app <app>` — filter by app
- `--json`
- `-q quiet`

### `mix deploy_ex.qa.attach_lb [app]`
- `--instance-id`
- `--target-group <arn>`
- `--port <int>` (default 4000)
- `--wait` — block until target healthy
- `-q quiet`

### `mix deploy_ex.qa.detach_lb [app]`
- `--instance-id`
- `--target-group <arn>`
- `-q quiet`

### `mix deploy_ex.qa.cleanup`
- `--dry-run`
- `-f force`, `-q quiet`

## Autoscaling

| Task | Switches |
|------|----------|
| `mix deploy_ex.autoscale.status <app>` | (uses `:aws_region` and `:env`) |
| `mix deploy_ex.autoscale.scale <app> <desired>` | `-e environment`, `-u update-limits` (also raise min/max if needed) |
| `mix deploy_ex.autoscale.refresh <app>` | `-e environment`, `-s strategy` (Rolling\|ReplaceRootVolume), `-a availability` (launch-first\|terminate-first), `--min-healthy-percentage`, `--max-healthy-percentage`, `--instance-warmup` (sec, default 300), `-w wait`, `--skip-matching`, `--no-tui` |
| `mix deploy_ex.autoscale.refresh_status <app>` | (no switches; reports active or last refresh) |

## Load Testing

| Task | Switches |
|------|----------|
| `mix deploy_ex.load_test` | (overview, no flags) |
| `mix deploy_ex.load_test.init` | (scaffolds k6 scripts under `./load_tests/`) |
| `mix deploy_ex.load_test.create_instance` | `--instance-type`, `--resource-group`, `--pem`, `-f force`, `-q quiet` |
| `mix deploy_ex.load_test.destroy_instance` | `-i instance-id`, `--all`, `-f force`, `-q quiet` |
| `mix deploy_ex.load_test.list` | `--json`, `-q quiet` |
| `mix deploy_ex.load_test.upload` | `-i instance-id`, `--script <path>`, `--pem`, `-q quiet` |
| `mix deploy_ex.load_test.exec` | `-i instance-id`, `--script <path>`, `--target-url`, `--prometheus-url`, `--pem`, `-q quiet` |

## Monitoring

### `mix deploy_ex.grafana.install_dashboard`
Install dashboards via SSH-tunnelled Grafana API.
- `-f, --file <path>` — local dashboard JSON
- `--id <int>` — dashboard ID from grafana.com
- `--grafana-ip` / `--grafana-port` (default 80)
- `--user` / `--password`
- `--pem`, `--resource-group`, `-q quiet`

## Ansible Argument Passthrough

Any flag deploy_ex doesn't recognise is forwarded to `ansible-playbook` verbatim — useful for passing through:

| Ansible flag | Purpose |
|---|---|
| `--inventory` | [Custom inventory file](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html) |
| `--limit` | [Restrict playbook to matching hosts](https://docs.ansible.com/ansible/latest/inventory_guide/intro_patterns.html) |
| `--extra-vars` (or `-e`) | Set extra variables: `--extra-vars bucket_name="my-bucket"` |
| `--tags` / `--skip-tags` | Run only / skip specific Ansible tags |

## See also

- [System Architecture](../explanation/architecture.md) — diagrams of the full pipeline
- [Configuration](configuration.md) — all `:deploy_ex` config keys, universal options, IaC switching, GitHub Actions secrets
- [Terraform Variables](terraform_variables.md) — per-app infrastructure schema
- [Codebase Summary](codebase_summary.md) — module inventory
- [Troubleshooting](../how-to/troubleshooting.md) — common problems and fixes
