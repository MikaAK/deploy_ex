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

## Prerequisites

- **Git** (required for change detection)
- **Terraform / OpenTofu** — auto-installed on macOS, Debian/Ubuntu, Alpine, Amazon Linux
- **Ansible** — auto-installed via pip3 if missing
- **`gh` CLI** — only needed for `--wait-for-build`; auto-installed when invoked
- **AWS credentials** — env vars, AWS CLI profile, or instance role
- **Windows** is not supported. Use WSL.

Every release in your `mix.exs` must end its `steps:` list with `:tar`.

## Install

```elixir
def deps do
  [
    {:deploy_ex, "~> 0.1"}
  ]
end
```

```bash
mix deps.get
```

## Quick Start

```bash
mix deploy_ex.full_setup -yak           # generate files + provision infra
mix deploy_ex.install_github_action     # install CI workflows
mix deploy_ex.install_migration_script  # generate the single migrate.sh overlay
git add .github rel/overlays && git commit -m "chore: deploy_ex bootstrap"
```

Flags: `-y` auto-approves Terraform, `-a` pulls AWS credentials from `~/.aws/credentials` into Ansible, `-k` skips the deploy step, `-p` skips the wait/setup step.

The `full_setup` pipeline runs:

1. `terraform.create_state_bucket` + `create_state_lock_table`
2. `terraform.build` → `apply` → `refresh`
3. `ansible.build` → wait → `ping` → `setup`
4. `deploy_ex.upload` → `ansible.deploy` (unless `-k`)

## Day-to-day Deploys

```bash
mix deploy_ex.release        # build changed apps (git + mix.lock + deps.tree diff)
mix deploy_ex.upload         # upload to S3 (4-way parallel by default)
mix ansible.deploy           # deploy to instances (or use --target-sha auto)
```

Filter with `--only app1 --only app2` or `--except app3`. `--force` rebuilds everything. Phoenix apps automatically run `mix assets.deploy` (esbuild + sass + tailwind + phx.digest).

Roll back:

```bash
mix ansible.rollback              # to previous release
mix ansible.rollback --select     # interactive picker from history
```

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
