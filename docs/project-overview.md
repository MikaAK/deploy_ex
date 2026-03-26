# DeployEx — Project Overview

DeployEx is an Elixir library that adds full AWS deployment capabilities to Elixir projects. It generates Terraform and Ansible configuration from templates, provides 73 Mix tasks for the entire deployment lifecycle, and manages releases via S3.

It supports both **umbrella** and **single-app** Elixir projects.

## Core Capabilities

- **Infrastructure Provisioning** — Terraform templates for EC2, RDS, S3, VPC, security groups, IAM, load balancers
- **Configuration Management** — Ansible playbooks for server setup, app deployment, monitoring stack
- **Release Management** — Build, upload, track releases in S3 with intelligent change detection
- **Monitoring** — Grafana UI, Grafana Loki (logging), Prometheus (metrics) — all optional
- **QA Nodes** — Ephemeral EC2 instances for testing specific release SHAs
- **Load Testing** — k6 runner instances with Prometheus metrics integration
- **Autoscaling** — ASG management with rolling and replace-root-volume refresh strategies
- **TUI** — Interactive terminal UI for command discovery and execution

## Project Structure

```
lib/
  deploy_ex/              # Core library modules
    aws_*.ex              # AWS service wrappers (EC2, S3, RDS, DynamoDB, ELB, ASG)
    release_uploader/     # Release build, upload, and change detection
    tui/                  # Terminal UI (dashboard, wizard, forms, progress)
    config.ex             # Runtime configuration with defaults
    project_context.ex    # Umbrella/single-app abstraction
    terraform.ex          # Terraform CLI wrapper
    ssh.ex                # SSH connections and tunneling
    utils.ex              # Shell execution, error aggregation
  mix/
    tasks/                # 73 Mix tasks (CLI interface)
    deploy_ex_helpers.ex  # Shared helpers for all tasks
priv/
  terraform/              # Terraform EEx templates + modules
  ansible/                # Ansible EEx templates + roles
config/
  config.exs              # ExAws and deploy_ex configuration
```

## Key Abstractions

| Module | Purpose |
|--------|---------|
| `DeployExHelpers` | Project introspection, SSH helpers, file I/O, release filtering |
| `DeployEx.Config` | All configuration access with defaults |
| `DeployEx.ProjectContext` | Abstracts umbrella vs single-app project detection |
| `DeployEx.Utils` | Shell command execution (always use this, never `System.cmd` directly) |
| `DeployEx.ReleaseUploader` | Coordinates release discovery, validation, and S3 upload |
| `DeployEx.Terraform` | Terraform CLI argument parsing and command execution |

## Getting Started Flow

```
1. mix deps.get                          # Install deploy_ex
2. mix deploy_ex.full_setup -yak         # Generate files + provision infrastructure
3. mix deploy_ex.install_github_action   # Set up CI/CD
4. mix deploy_ex.release                 # Build releases (change detection)
5. mix deploy_ex.upload                  # Upload to S3
6. mix ansible.deploy                    # Deploy to EC2 instances
```

For detailed setup, see [Deployment Guide](deployment-guide.md).
For all available commands, see [API Reference](api-reference.md).
For configuration options, see [Configuration Guide](configuration-guide.md).
