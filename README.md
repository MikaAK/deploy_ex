# DeployEx

> ⚠️ **Status: WIP — not yet on Hex.** Requires OTP 27+; [erlexec fails to compile on OTP 26](https://github.com/saleyn/erlexec/issues/189).

Add full AWS deployment to any Elixir application — umbrella or single-app — backed by Terraform, Ansible, and S3.

DeployEx ships **68 Mix tasks**, EEx templates for Terraform and Ansible, an interactive TUI wizard, smart change-detection releases, ephemeral QA nodes with optional CI-gated deploys, and a priv-template upgrade pipeline with optional LLM-assisted merging.

## Features

- **Infrastructure** — VPC, EC2, RDS, ALB, IAM, security groups, S3 buckets, DynamoDB state lock
- **Configuration** — Ansible roles for BEAM tuning, Loki + Alloy log shipping, Prometheus, Grafana, Redis, Let's Encrypt
- **Releases** — Build only changed apps (git diff + mix.lock + deps tree), upload in parallel, track current + history in S3
- **QA nodes** — Ephemeral EC2 instances per SHA, optional public-IP TLS via LLM-assisted host rewrite, optional `--wait-for-build` to gate on GitHub Actions
- **Priv pipeline** — `export_priv` to take ownership of templates, `upgrade_priv` with interactive / AI-assisted / autonomous LLM merge
- **TUI** — Wizard, dashboards, per-hunk diff viewer; auto-disables in CI / non-TTY
- **CI** — `gh`-CLI–based workflow detection, branch glob matching, run polling

Optional services (toggle off with `--no-*`): Postgres, Redis, Grafana UI, Loki, Prometheus, Sentry.

## Quickstart

Each step is one action. Run them in order; deploys flow through GitHub Actions, not your machine.

### Step 1 — Add the dependency

Edit `mix.exs`:

```elixir
def deps do
  [
    {:deploy_ex, "~> 0.1"}
  ]
end
```

Make sure every release in `mix.exs` ends its `steps:` list with `:tar`.

### Step 2 — Fetch deps

```bash
mix deps.get
```

### Step 3 — Bootstrap AWS infrastructure

```bash
mix deploy_ex.full_setup -ya
```

**What it does:** creates the Terraform state bucket + lock table, generates `./deploys/{terraform,ansible}/`, runs `terraform apply` to provision VPC + EC2 + RDS + S3 + IAM, then runs `ansible.setup` to bootstrap the instances. It does **not** deploy any release — that's CI's job (Step 6 onward).

**Flags:** `-y` auto-approves terraform, `-a` pulls AWS credentials from `~/.aws/credentials` into Ansible group_vars, `-p` skips the wait + ansible.setup steps if you want infra-only.

**Time:** 10–25 minutes for the first run (mostly EC2 instance boot and Ansible bootstrap).

### Step 4 — Review per-app config

```bash
$EDITOR deploys/terraform/variables.tf
```

The `<app>_project` map declares per-app infrastructure: instance type, count, EBS, load balancer, autoscaling. Defaults are conservative (`t3.nano`, single instance, no LB) — adjust before applying real workloads. See [Terraform Variables](guides/reference/terraform_variables.md) for the schema.

### Step 5 — Apply your config

```bash
mix terraform.plan
mix terraform.apply -y
```

`plan` previews the diff — read it. `apply` executes.

### Step 6 — Generate CI workflows

```bash
mix deploy_ex.install_github_action
```

Writes `.github/workflows/deploy-ex-release.yml` (build + upload + deploy on every push) and `.github/workflows/setup-new-nodes.yml` (every 15 min: detects instances missing the `SetupComplete` tag and runs `ansible.setup`).

### Step 7 — Generate the migration script

```bash
mix deploy_ex.install_migration_script
```

Writes `rel/overlays/bin/migrate.sh` — Mix copies it into every release tarball, so on the server it lives at `/srv/<release>/bin/migrate.sh`.

### Step 8 — Commit the generated files

```bash
git add .github rel/overlays deploys
git commit -m "chore: deploy_ex bootstrap"
```

You own everything in `deploys/`. Subsequent `mix terraform.build` / `mix ansible.build` runs are additive — they merge new app entries into your customised files without overwriting them.

### Step 9 — Add GitHub repository secrets

In GitHub: **Settings → Secrets and variables → Actions → New repository secret**.

| Secret | Value |
|---|---|
| `DEPLOY_EX_AWS_ACCESS_KEY_ID` | AWS access key (the deploy IAM user, not your console login) |
| `DEPLOY_EX_AWS_SECRET_ACCESS_KEY` | matching secret key |
| `EC2_PEM_FILE` | full contents of `deploys/terraform/*.pem`. Copy with `cat deploys/terraform/*.pem \| pbcopy` (macOS) |

### Step 10 — Add runtime env-var secrets (`__DEPLOY_EX__*`)

For every env var your app needs at compile or runtime, add a secret prefixed `__DEPLOY_EX__`. Examples:

| Secret name | Becomes env var |
|---|---|
| `__DEPLOY_EX__DATABASE_URL` | `DATABASE_URL` |
| `__DEPLOY_EX__SECRET_KEY_BASE` | `SECRET_KEY_BASE` |
| `__DEPLOY_EX__SENTRY_DSN` | `SENTRY_DSN` |

The prefix is stripped automatically. Available during `mix compile` (so runtime config can read them) and exported on deployed instances.

### Step 11 — Allow workflow write permissions

In GitHub: **Settings → Actions → General → Workflow permissions** — select **"Read and write permissions"**. Required for the workflow's auto-commit step (when `terraform.build` adds drift to `deploys/`).

### Step 12 — Handle branch protections (if any)

If you have branch protection on `main`, the auto-commit step will fail. Either:

- **Disable protection on `main`** (simplest, fine for solo / small teams), or
- **Add a PAT or GitHub App token with bypass permissions** and replace `${{ secrets.GITHUB_TOKEN }}` references in the workflow with your token. Document the rotation owner in your team runbook.

See [Configuration → GitHub Actions Setup](guides/reference/configuration.md#github-actions-setup) for full details.

### Step 13 — Trigger your first CI deploy

```bash
git push origin main
```

Watch progress at `https://github.com/<owner>/<repo>/actions`. The workflow:

1. Compiles your project with `__DEPLOY_EX__*` secrets injected as env vars
2. `mix deploy_ex.ssh.authorize` — whitelists the runner IP
3. `mix deploy_ex.release` — builds changed apps only
4. `mix deploy_ex.upload` — pushes tarballs to S3 (auto-`--qa` for `qa/*` branches)
5. Writes the PEM file from the secret onto the runner
6. `mix ansible.deploy --target-sha <sha>` — deploys to instances
7. `mix deploy_ex.ssh.authorize -r` — deauthorizes the runner IP

### Daily loop

After Step 13, your day-to-day is just:

```bash
git push origin main          # CI handles release → upload → deploy
```

Change detection compares git SHAs, `mix.lock` diffs, and `mix deps.tree` — only changed apps rebuild. To roll back: `mix ansible.rollback` or `mix ansible.rollback --select` for a picker.

For SSH and ops commands, see [SSH (Eval Pattern)](#ssh-eval-pattern) below.

## Prerequisites

- **Git** (required for change detection)
- **Terraform / OpenTofu** — auto-installed on macOS, Debian/Ubuntu, Alpine, Amazon Linux
- **Ansible** — auto-installed via pip3 if missing
- **`gh` CLI** — only needed for `--wait-for-build`; auto-installed when invoked
- **AWS credentials** — env vars, AWS CLI profile, or instance role
- **Windows** is not supported. Use WSL.

Every release in your `mix.exs` must end its `steps:` list with `:tar`.

## What `full_setup` Actually Does

The `mix deploy_ex.full_setup` step from the Quickstart chains:

1. `terraform.create_state_bucket` + `create_state_lock_table` — S3 + DynamoDB for Terraform state
2. `terraform.build` → `apply` → `refresh` — generate and apply infra
3. `ansible.build` → wait → `ping` → `setup` — generate inventory + bootstrap servers

It stops there. Releases are deployed by CI (or manually with `mix deploy_ex.release && mix deploy_ex.upload && mix ansible.deploy`).

## Filtering Releases and Rollbacks

```bash
mix deploy_ex.release --only app1 --only app2     # build subset
mix deploy_ex.release --except app3               # exclude
mix deploy_ex.release --force                     # rebuild everything

mix ansible.deploy --target-sha abc1234           # specific SHA
mix ansible.deploy --target-sha auto              # newest on current branch
mix ansible.rollback                              # previous release
mix ansible.rollback --select                     # interactive picker
```

Phoenix apps automatically run `mix assets.deploy` (esbuild + sass + tailwind + phx.digest) when assets are detected.

## SSH (Eval Pattern)

`mix deploy_ex.ssh -s` prints the ssh command instead of running it, so you can chain it into a shell:

```bash
eval "$(mix deploy_ex.ssh -s my_app)"             # SSH directly
eval "$(mix deploy_ex.ssh -s --root my_app)"      # as root
eval "$(mix deploy_ex.ssh -s --log my_app)"       # tail logs
eval "$(mix deploy_ex.ssh -s --iex my_app)"       # remote IEx
```

Wrap it in a shell function so you can `my-app-ssh app_name --log` from anywhere:

```bash
# bash / zsh
alias my-app-ssh='pushd ~/path/to/project >/dev/null && mix compile --quiet && eval "$(mix deploy_ex.ssh -s $@)" && popd >/dev/null'

# fish
function my-app-ssh
  pushd ~/path/to/project &&
  set ssh_command (mix deploy_ex.ssh $argv -s) &&
  eval $ssh_command &&
  popd
end
```

Authorise SSH access first — by default ingress is locked down:

```bash
mix deploy_ex.ssh.authorize       # add current IP
mix deploy_ex.ssh.authorize --remove
```

Full reference: [Connecting to Nodes](guides/how-to/connecting_to_nodes.md).

## Managing Infrastructure (Terraform Variables)

Per-app infrastructure — instance type, count, EBS, load balancer, **autoscaling** — is declared in `deploys/terraform/variables.tf`. Edit the file, then `mix terraform.apply`. Don't manage scale or instance type via the AWS console; deploy_ex is the source of truth.

```hcl
my_app_project = {
  my_app = {
    instance_type = "t3.small"
    instance_count = 2

    load_balancer = { enable = true, port = 80, instance_port = 4000 }

    autoscaling = {
      enable                  = true
      min_size                = 2
      max_size                = 10
      desired_capacity        = 3
      cpu_target_percent      = 60
      ignore_capacity_changes = false   # see Terraform Variables guide
    }
  }
}
```

Standard workflow:

```bash
mix terraform.plan          # preview changes
mix terraform.apply         # apply
mix ansible.build           # if instance count or apps changed
mix ansible.setup --only my_app
mix ansible.deploy --only my_app
```

`mix deploy_ex.autoscale.scale` and `mix deploy_ex.autoscale.refresh` are runtime levers (manual override, rolling deploy) — they call AWS APIs directly and don't edit `variables.tf`. The `ignore_capacity_changes` flag controls whether those runtime overrides survive the next `terraform.apply`.

The full schema (templates, scheduled scaling, EBS pool, multi-Launch-Template setups) is in [Terraform Variables](guides/reference/terraform_variables.md). Autoscaling internals: [Autoscaling Explanation](guides/explanation/autoscaling.md).

## QA Nodes

Ephemeral EC2 instances for testing specific SHAs:

```bash
mix deploy_ex.qa.create my_app                                       # prompt for SHA
mix deploy_ex.qa.create my_app --sha abc1234 --tag canary --attach-lb
mix deploy_ex.qa.create my_app --public-ip-cert --wait-for-build     # CI-gated, public-IP TLS
mix deploy_ex.qa.deploy my_app --sha def5678
mix deploy_ex.qa.list
mix deploy_ex.qa.destroy my_app
mix deploy_ex.qa.cleanup --dry-run
```

`--public-ip-cert` issues a Let's Encrypt cert via HTTP-01 and triggers an LLM-assisted rewrite of host config so the node serves traffic from its public IP. Originals are restored automatically by `qa.destroy`. Requires `:llm_provider` configured.

`--wait-for-build` commits + pushes the rewrites to a QA branch, finds the matching GitHub Actions workflow (parsing `on.push.branches` globs and looking for jobs that run `mix deploy_ex.release`), waits up to `--build-timeout` minutes, and prompts a 4-option recovery menu on failure (rollback / leave / destroy node only / revert + repush).

See [QA Nodes guide](guides/how-to/qa_nodes.md) for the full flow.

## Configuration

```elixir
config :deploy_ex,
  aws_region: "us-west-2",
  aws_resource_group: "MyApp Backend",
  aws_release_bucket: "myapp-elixir-deploys-prod",
  deploy_folder: "./deploys",
  llm_provider: {LangChain.ChatModels.ChatAnthropic, model: "claude-sonnet-4-6"}
```

`llm_provider` is required for `--ai-review`, `--llm-merge`, and `--public-ip-cert`. Pass an API key via LangChain config: `config :langchain, anthropic_key: System.get_env("ANTHROPIC_API_KEY")`.

See the [Configuration Reference](guides/reference/configuration.md) for every key, environment variable, and the redeploy whitelist/blacklist format.

## Customising Templates

The Terraform / Ansible templates live inside the dependency. To take ownership:

```bash
mix deploy_ex.export_priv
```

This renders every template with your project's config and writes them to `./deploys/`, plus a `.deploy_ex_manifest.exs` recording each file's SHA256. From here, you own the files.

After upgrading the `deploy_ex` dep, sync upstream changes:

```bash
mix deploy_ex.upgrade_priv               # interactive per-hunk DiffViewer
mix deploy_ex.upgrade_priv --ai-review   # LLM proposes accept/reject per file
mix deploy_ex.upgrade_priv --llm-merge   # LLM applies all changes (with backup)
```

The upgrade pipeline uses `DeployEx.ChangePlanner` to detect renames, splits, and merges via Jaro distance + LLM disambiguation, so renamed-but-edited files don't get clobbered.

## Tear Down

```bash
mix terraform.drop                       # destroy infrastructure
mix deploy_ex.full_drop                  # destroy + remove ./deploys + .github workflows + state bucket
```

## Documentation

The [`guides/`](guides/) folder is the canonical documentation:

- [Introduction](guides/introduction.md)
- **Tutorial** — [Getting Started](guides/tutorials/getting_started.md) (covers multi-Phoenix-app config)
- **How-to**
  - [Deploying Releases](guides/how-to/deploying_releases.md)
  - [QA Nodes](guides/how-to/qa_nodes.md) — including `--wait-for-build`, public-IP TLS, QA tag schema
  - [Connecting to Nodes](guides/how-to/connecting_to_nodes.md) — SSH, eval pattern, alias recipes
  - [Managing Infrastructure](guides/how-to/managing_infrastructure.md) — terraform, priv upgrades, EBS, teardown
  - [Autoscaling](guides/how-to/autoscaling.md) — scale, refresh, deployment strategies
  - [Database Operations](guides/how-to/database_operations.md)
  - [Load Testing](guides/how-to/load_testing.md) — k6 runners + Prometheus remote-write
  - [Monitoring](guides/how-to/monitoring.md) — Grafana, Loki, Prometheus, Sentry, dashboards
  - [Clustering](guides/how-to/clustering.md) — libcluster + EC2Tag strategy
  - **[Troubleshooting](guides/how-to/troubleshooting.md)** — Ansible, SSH, autoscaling, RDS upgrades, monitoring, tags
- **Reference**
  - [Mix Tasks](guides/reference/mix_tasks.md) — every task with switches
  - [Configuration](guides/reference/configuration.md) — every config key, universal options, IaC switching, GitHub secrets
  - [Terraform Variables](guides/reference/terraform_variables.md) — per-app infrastructure schema
  - [Codebase Summary](guides/reference/codebase_summary.md) — module inventory
  - [Testing](guides/reference/testing.md)
- **Explanation**
  - [System Architecture](guides/explanation/architecture.md) — diagrams of every pipeline
  - [Autoscaling Internals](guides/explanation/autoscaling.md) — instance lifecycle, version consistency, IAM, deployment strategies
  - [Code Standards](guides/explanation/code_standards.md)

Or run `mix deploy_ex` to launch the interactive TUI wizard for live discovery.

## Contributing

Tests:

```bash
mix test                       # all
mix test test/deploy_ex/foo_test.exs:42
```

No mocks — dependency injection via parameters. See [Testing Guide](guides/reference/testing.md) and [Code Standards](guides/explanation/code_standards.md) before submitting changes.

## Goals / Roadmap

- [x] Deploy rollbacks
- [x] S3-backed Terraform state
- [x] Subnet AZ dispersal in networking layer
- [x] OpenTofu support via `:iac_tool`
- [ ] Canary deploys
- [ ] Automated IP whitelist removal lambda (paired with `mix deploy_ex.ssh.authorize`)
- [ ] Sentry integration (currently WIP)
- [ ] Vault integration
- [ ] Static way to set up Redis from apps
- [ ] Auto-run `ansible.setup` on nodes created via GitHub Actions

## Credits

Big thanks to [@alevan](https://github.com/alevan) for figuring out the Ansible side of things and providing the foundation for everything in `priv/ansible/`. This project wouldn't exist without his help.

Also leans on [`libcluster_ec2_tag_strategy`](https://github.com/MikaAK/libcluster_ec2_tag_strategy) for cluster discovery — see [Clustering](guides/how-to/clustering.md).

## License

See `LICENSE` (if present).
