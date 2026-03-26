# Codebase Summary

## File Inventory

| Directory | Files | LOC (approx) | Purpose |
|-----------|-------|---------------|---------|
| `lib/deploy_ex/` | 38 | ~5,800 | Core library modules |
| `lib/deploy_ex/release_uploader/` | 6 | ~500 | Release management subsystem |
| `lib/deploy_ex/tui/` | 6 | ~1,600 | Terminal UI components |
| `lib/mix/tasks/` | 73 | ~6,000 | Mix task CLI interface |
| `lib/mix/deploy_ex_helpers.ex` | 1 | ~330 | Shared task helpers |
| `priv/terraform/` | 13 | ~1,200 | Terraform templates + modules |
| `priv/ansible/` | 30+ | ~2,000 | Ansible templates + roles |
| `test/` | 12 | ~800 | Tests + fixtures |
| **Total** | **~170 source** | **~18,000** | |

## Module Inventory by Subsystem

### AWS Services (9 modules, ~1,950 LOC)

| Module | LOC | Purpose |
|--------|-----|---------|
| `AwsMachine` | 446 | EC2 instance lifecycle, discovery by tags |
| `AwsAutoscaling` | 406 | Auto Scaling Group operations |
| `AwsInfrastructure` | 299 | Subnet, VPC, AMI, IAM discovery |
| `AwsLoadBalancer` | 220 | ELBv2 target group management |
| `AwsDatabase` | 139 | RDS instance discovery |
| `AwsSecurityGroup` | 114 | Security group lookup |
| `AwsBucket` | 105 | S3 bucket operations |
| `AwsDynamoDB` | 84 | DynamoDB table operations |
| `AwsIpWhitelister` | 59 | Security group ingress rules |

### Release Management (8 modules, ~430 LOC)

| Module | LOC | Purpose |
|--------|-----|---------|
| `ReleaseUploader` | 149 | Release coordination (build, validate, upload) |
| `UpdateValidator` | 256 | Change detection (git diff, deps tree, lock file) |
| `ReleaseTracker` | 120 | S3-backed current/history tracking |
| `State` | 88 | Release state struct and builders |
| `RedeployConfig` | 68 | Whitelist/blacklist config parser |
| `AwsManager` | 35 | Low-level S3 release operations |
| `MixDepsTreeParser` | 40 | `mix deps.tree` output parser |
| `MixLockFileDiffParser` | 22 | `mix.lock` git diff parser |

### Infrastructure (8 modules, ~700 LOC)

| Module | LOC | Purpose |
|--------|-----|---------|
| `Utils` | 187 | Shell execution, error aggregation |
| `Terraform` | 175 | Terraform CLI wrapper |
| `TerraformState` | 175 | Terraform state reader (local/S3) |
| `SSH` | 134 | SSH connections, tunneling, command execution |
| `Config` | 92 | Runtime configuration with defaults |
| `PrivManifest` | 93 | Template manifest tracking (SHA256) |
| `SystemdController` | 26 | Systemd service management |
| `Ansible` | 26 | Ansible argument parsing |

### TUI (7 modules, ~1,630 LOC)

| Module | LOC | Purpose |
|--------|-----|---------|
| `TUI.Wizard.CommandRegistry` | 866 | Command metadata for wizard |
| `TUI.Wizard.Form` | 444 | Dynamic form builder |
| `TUI.Wizard` | 394 | Interactive command wizard |
| `TUI.Progress` | 310 | Progress bar and task tracking |
| `TUI.DeployProgress` | 270 | Deployment progress tracking |
| `TUI.Select` | 157 | Multi-select widget |
| `TUI.Dashboard` | 136 | Real-time dashboard |
| `TUI` | 28 | Feature flag and setup |

### Specialized Operations (5 modules, ~1,140 LOC)

| Module | LOC | Purpose |
|--------|-----|---------|
| `QaNode` | 603 | QA instance lifecycle + S3 state |
| `K6Runner` | 428 | k6 load testing runner instances |
| `Grafana` | 130 | Dashboard management via SSH tunnel |
| `LlmMerge` | 85 | Optional AI-assisted template merging |
| `IpFinder` | 9 | External IP detection |

## Key Dependencies

| Package | Version | Purpose | Type |
|---------|---------|---------|------|
| `ex_aws` | ~> 2.3 | AWS SDK wrapper | Runtime |
| `ex_aws_s3` | ~> 2.3 | S3 operations | Runtime |
| `ex_aws_ec2` | ~> 2.0 | EC2 operations | Runtime |
| `ex_aws_rds` | ~> 2.0 | RDS operations | Runtime |
| `ex_aws_dynamo` | ~> 4.2 | DynamoDB operations | Runtime |
| `ex_aws_elastic_load_balancing` | ~> 3.0 | ELB operations | Runtime |
| `jason` | ~> 1.3 | JSON encoding/decoding | Runtime |
| `error_message` | ~> 0.2 | Structured error tuples | Runtime |
| `req` | ~> 0.3 | HTTP client | Runtime |
| `hackney` | ~> 1.18 | HTTP adapter for ExAws | Runtime |
| `sweet_xml` | ~> 0.7 | XPath XML parsing | Runtime |
| `elixir_xml_to_map` | ~> 3.0 | XML to map conversion | Runtime |
| `exexec` | ~> 0.2 | Interactive process execution | Runtime |
| `ex_ratatui` | ~> 0.4 | Terminal UI rendering | Runtime |
| `langchain` | ~> 0.6 | LLM integration (optional) | Optional |

## Entry Points

The primary interface is Mix tasks in `lib/mix/tasks/`. All tasks:
1. Call `DeployExHelpers.check_valid_project()` to validate project type
2. Parse CLI args with `OptionParser`
3. Delegate to core modules in `lib/deploy_ex/`

The TUI wizard (`mix deploy_ex`) provides a browsable interface to all tasks.

See also: [System Architecture](system-architecture.md) | [Project Overview](project-overview.md)
