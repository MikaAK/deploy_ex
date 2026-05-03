# Codebase Summary

## File Inventory

| Directory | Files | Purpose |
|-----------|-------|---------|
| `lib/deploy_ex/` | 50+ `.ex` files | Core library (AWS wrappers, orchestration, QA, priv pipeline, TUI) |
| `lib/deploy_ex/release_uploader/` | 6 | Release management subsystem |
| `lib/deploy_ex/release_lookup/` | 1 | Git-backed release filter |
| `lib/deploy_ex/tui/` | 7 | TUI screens (wizard, dashboard, diff viewer, progress) |
| `lib/deploy_ex/tui/wizard/` | 2 | Wizard form + command registry |
| `lib/mix/tasks/` | 68 | Mix task CLI surface |
| `lib/mix/deploy_ex_helpers.ex` | 1 | Shared helpers (project introspection, SSH, file I/O) |
| `priv/terraform/` | 13 + 3 modules | Terraform templates (.tf, .tf.eex) and modules |
| `priv/ansible/` | 30+ | Ansible roles, playbooks, group_vars, inventories |
| `test/` | 20 | Tests + fixtures |

## Module Inventory

### AWS Wrappers (`lib/deploy_ex/aws_*.ex`)

| Module | Purpose |
|--------|---------|
| `AwsMachine` | EC2 lifecycle, tag-based discovery, instance group queries |
| `AwsAutoscaling` | ASG describe, scale, instance refresh, scaling policies |
| `AwsInfrastructure` | VPC, subnet, key pair, IAM profile, AMI lookups |
| `AwsLoadBalancer` | ELBv2 target group register/deregister + health waits |
| `AwsDatabase` | RDS describe, password retrieval (via TerraformState) |
| `AwsSecurityGroup` | Security group lookup by prefix or VPC |
| `AwsBucket` | S3 create/list/delete with recursive truncation |
| `AwsDynamodb` | DynamoDB CRUD for the state lock table |
| `AwsIpWhitelister` | Authorize/revoke /32 SSH ingress on a SG |

### Orchestration

| Module | Purpose |
|--------|---------|
| `Terraform` | CLI wrapper, arg parsing, output JSON, instance/IP extraction |
| `TerraformState` | S3/local state reader; `get_output/get_resource_attribute` |
| `Ansible` | Argument parsing for ansible-playbook |
| `AnsibleRoles` | Sync `priv/ansible/roles/` into `./deploys/ansible/roles/` |
| `Utils` | Shell execution wrappers + status tuple aggregation |
| `SSH` | Erlang SSH client + `ssh -L` tunnels + port allocation |
| `SystemdController` | Build `systemctl start/stop/restart` commands |
| `IpFinder` | Whoami service for current public IP |

### Release Management

| Module | Purpose |
|--------|---------|
| `ReleaseUploader` | Top-level coordination (build, validate, upload) |
| `ReleaseUploader.State` | Release struct |
| `ReleaseUploader.AwsManager` | S3 upload + tagging |
| `ReleaseUploader.RedeployConfig` | Whitelist/blacklist parser |
| `ReleaseUploader.UpdateValidator` | Change detection across git + lock + deps tree |
| `ReleaseUploader.UpdateValidator.MixDepsTreeParser` | Parse `mix deps.tree` (file: `mix_dep_tree_parser.ex`) |
| `ReleaseUploader.UpdateValidator.MixLockFileDiffParser` | Parse `git diff -- mix.lock` |
| `ReleaseLookup` | Interactive release picker (TUI + git filter) |
| `ReleaseLookup.GitImpl` | `git rev-list` wrapper |
| `ReleaseTracker` | S3-backed `current_release` and `release_history` |
| `ReleaseController` | Thin delegating layer to ReleaseTracker |

### Priv Pipeline

| Module | Purpose |
|--------|---------|
| `PrivRenderer` | Render priv/terraform + priv/ansible EEx templates to a temp dir |
| `ChangePlanner` | Compare rendered tree vs `./deploys/`; classify rename / split / merge |
| `Diff` | Unified diff via `diff -u`, parse hunks, apply selectively |
| `LLMMerge` | LangChain-based two-way merge + proposal review |
| `PrivManifest` | SHA256 manifest read/write/lookup; generates `.deploy_ex_manifest.exs` |

### QA Pipeline

| Module | Purpose |
|--------|---------|
| `QaNode` | EC2 lifecycle, S3 state, LB attach/detach, interactive picker |
| `QaPlaybook` | Per-QA-node throwaway Ansible playbook generation |
| `QaHostRewrite` | LLM-driven rewrite of Phoenix endpoint config for public-IP TLS |
| `GitOperations` | Resolve QA branch, commit + push, revert + push, delete remote |
| `GitHubActions` | Workflow detection (yml glob match), gh-CLI run polling |
| `K6Runner` | Load-test EC2 runner mirror of QaNode |

### TUI

| Module | Purpose |
|--------|---------|
| `TUI` | Logger silencing + setup helpers |
| `TUI.Wizard` | Top-level interactive command browser |
| `TUI.Wizard.CommandRegistry` | Metadata for every Mix task |
| `TUI.Wizard.Form` | Dynamic form builder for arguments |
| `TUI.Select` | Single + multi-select picker |
| `TUI.Progress` | Step-by-step progress bar |
| `TUI.DeployProgress` | Specialized deploy progress rendering |
| `TUI.Dashboard` | Live dashboard (e.g. load_balancer.health --watch) |
| `TUI.DiffViewer` | Per-hunk diff review with accept/reject |

### Other

| Module | Purpose |
|--------|---------|
| `Config` | All runtime config access |
| `ProjectContext` | Umbrella vs single-app abstraction |
| `Grafana` | Dashboard install via SSH-tunnelled Grafana API |
| `ToolInstaller` | Detect platform, install terraform/ansible/gh |

## Key Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `ex_aws` | ~> 2.3 | AWS SDK core |
| `ex_aws_s3` | ~> 2.3 | S3 |
| `ex_aws_ec2` | ~> 2.0 | EC2 |
| `ex_aws_rds` | ~> 2.0 | RDS |
| `ex_aws_dynamo` | ~> 4.2 | DynamoDB |
| `ex_aws_elastic_load_balancing` | ~> 3.0 | ELB / ALB |
| `jason` | ~> 1.3 | JSON encode/decode |
| `error_message` | ~> 0.2 | `%ErrorMessage{}` structured errors |
| `req` | ~> 0.3 | HTTP client (Grafana, IpFinder) |
| `hackney` | ~> 1.18 | HTTP adapter for ExAws |
| `sweet_xml` | ~> 0.7 | XPath XML extraction |
| `elixir_xml_to_map` | ~> 3.0 | XML to map for AWS responses |
| `exexec` | ~> 0.2 | Interactive PTY commands |
| `erlexec` | ~> 2.0 | OS process execution |
| `configparser_ex` | >= 4.0.0 | Parse `~/.aws/credentials` |
| `ex_ratatui` | ~> 0.4 | Terminal UI rendering |
| `langchain` | ~> 0.6 | LLM integration (used by QaHostRewrite, LLMMerge, upgrade_priv `--ai-review`/`--llm-merge`) |
| `yaml_elixir` | ~> 2.11 | Parse `.github/workflows/*.yml` |

## Entry Points

The primary interface is Mix tasks in `lib/mix/tasks/`. Every task:

1. Calls `DeployExHelpers.check_valid_project()` to validate it's running in a Mix project
2. Parses CLI args with `OptionParser`
3. Optionally calls `DeployEx.TUI.setup_no_tui(opts)` to honor `--no-tui`
4. Delegates to core modules in `lib/deploy_ex/`

The TUI wizard (`mix deploy_ex`) provides a browsable interface to every task with form-based input.

See also: [System Architecture](../explanation/architecture.md) | [Project Overview](../introduction.md)
