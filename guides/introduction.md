# DeployEx — Project Overview

DeployEx is an Elixir library that adds full AWS deployment capabilities to Elixir projects. It generates Terraform and Ansible configuration from EEx templates, ships **68 Mix tasks** that cover the entire deployment lifecycle, and manages releases through S3.

It supports both **umbrella** and **single-app** Elixir projects.

## Core Capabilities

- **Infrastructure provisioning** — Terraform templates for VPC, EC2, RDS, S3, IAM, ALB, security groups
- **Configuration management** — Ansible roles and playbooks for server bootstrap, app deploy, monitoring
- **Release management** — Build, upload, track and roll back releases via S3 with smart change detection
- **QA nodes** — Ephemeral EC2 instances for testing specific release SHAs, optionally CI-gated and behind a public-IP TLS cert
- **Priv pipeline** — Export deploy_ex templates into your repo, then upgrade them with interactive, AI-assisted, or autonomous LLM merges
- **Autoscaling** — Manage ASG capacity and instance refresh (rolling, replace-root-volume)
- **Load testing** — k6 runner instances with Prometheus metrics integration
- **Monitoring** — Optional Grafana UI, Loki logs, Prometheus metrics, Sentry, Redis, Postgres
- **TUI** — Interactive terminal wizard, progress streams, and per-hunk diff viewer
- **CI integration** — `gh` CLI workflow detection, branch matching, and `--wait-for-build` gating for QA flows

## Project Structure

```
lib/
  deploy_ex/                         # Core library (50+ modules)
    aws_*.ex                         # AWS service wrappers (EC2, S3, RDS, DynamoDB, ELB, ASG, IAM)
    change_planner.ex                # Diff planner for priv upgrades (rename/split/merge detection)
    config.ex                        # Runtime configuration with smart defaults
    diff.ex                          # Unified diff + per-hunk apply
    git_operations.ex                # QA branch resolve / commit / push / revert / delete
    github_actions.ex                # Workflow discovery + run polling via gh CLI
    grafana.ex                       # Dashboard install via SSH tunnel
    ip_finder.ex                     # External IP detection
    k6_runner.ex                     # Load test EC2 runner
    llm_merge.ex                     # LangChain merge / proposal review
    priv_manifest.ex                 # SHA256 manifest tracking for ./deploys/
    priv_renderer.ex                 # Render priv EEx templates to temp
    project_context.ex               # Umbrella/single-app abstraction
    qa_host_rewrite.ex               # LLM-assisted host config rewrites for QA SSL
    qa_node.ex                       # QA EC2 lifecycle + S3 state
    qa_playbook.ex                   # Per-QA-node throwaway Ansible playbooks
    release_controller.ex
    release_lookup.ex                # Interactive release picker (SHA / branch / type)
    release_tracker.ex               # Current + history tracking in S3
    release_uploader.ex              # Build / validate / upload + change detection
    ssh.ex                           # SSH connections and tunneling
    systemd_controller.ex            # Systemd unit command builders
    terraform.ex / terraform_state.ex
    tool_installer.ex                # Cross-platform install for terraform/ansible/gh
    tui.ex / tui/                    # ExRatatui wizard, dashboard, diff viewer, progress
    utils.ex                         # Shell execution + status aggregation
  mix/
    deploy_ex_helpers.ex             # Shared helpers used by every task
    tasks/                           # 68 Mix tasks (CLI surface)
priv/
  ansible/                           # roles/, playbooks, group_vars, host_vars
  terraform/                         # .tf + .tf.eex templates and modules
  *.eex                              # GitHub Actions + migration_script templates
config/
  config.exs                         # ExAws + deploy_ex configuration
guides/                              # Documentation (this folder)
```

## Key Abstractions

| Module | Purpose |
|--------|---------|
| `DeployExHelpers` | Project introspection, SSH helpers, file I/O, release filtering |
| `DeployEx.Config` | All configuration access with defaults |
| `DeployEx.ProjectContext` | Abstracts umbrella vs single-app project detection |
| `DeployEx.Utils` | Shell command execution (always use this, never `System.cmd` directly) |
| `DeployEx.ReleaseUploader` | Coordinates release discovery, validation, S3 upload |
| `DeployEx.QaNode` | QA instance lifecycle and S3 state |
| `DeployEx.ChangePlanner` | Priv-upgrade diff planning (rename/split/merge) |
| `DeployEx.GitHubActions` | Workflow detection + run polling for `--wait-for-build` |
| `DeployEx.Terraform` | Terraform CLI argument parsing and command execution |

## Getting Started Flow

```
1. mix deps.get                          # install deploy_ex
2. mix deploy_ex.full_setup -yak         # generate files + provision infrastructure
3. mix deploy_ex.install_github_action   # set up CI/CD
4. mix deploy_ex.release                 # build releases (change detection)
5. mix deploy_ex.upload                  # upload to S3
6. mix ansible.deploy                    # deploy to EC2 instances
```

For detailed setup, see [Getting Started](tutorials/getting_started.md).
For all available commands, see [Mix Tasks Reference](reference/mix_tasks.md).
For configuration options, see [Configuration Reference](reference/configuration.md).
For architecture, see [System Architecture](explanation/architecture.md).
