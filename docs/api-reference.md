# API Reference — Mix Tasks

Universal options available on most tasks: `--only` (multi), `--except` (multi), `--force`/`-f`, `--quiet`/`-q`, `--no-tui`

## Core Deployment

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix deploy_ex` | Interactive wizard for all commands | `--no-tui` |
| `mix deploy_ex.full_setup` | Complete infrastructure + app setup | `-y` auto-approve, `-a` auto-pull AWS, `-k` skip-deploy, `-p` skip-setup |
| `mix deploy_ex.full_drop` | Remove all DeployEx infrastructure | |
| `mix deploy_ex.release` | Build releases for changed apps | `-f` force, `--only`/`--except`, `-r` recompile, `--aws-region`, `--aws-bucket` |
| `mix deploy_ex.upload` | Upload releases to S3 | `--parallel`, `--qa`, `--aws-region`, `--aws-bucket` |
| `mix deploy_ex.remake` | Replace + redeploy an app node | `--no-deploy` |

## Terraform

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix terraform.init` | Initialize Terraform | `-d` directory, `-u` upgrade |
| `mix terraform.build` | Generate .tf files from templates | `--no-database`, `--no-loki`, `--no-grafana`, `--no-redis`, `--no-prometheus`, `--no-sentry`, `--env`, `--aws-region` |
| `mix terraform.plan` | Preview infrastructure changes | `--var-file`, `--target` (multi) |
| `mix terraform.apply` | Provision infrastructure | `-y` auto-approve, `--var-file`, `--target` (multi) |
| `mix terraform.refresh` | Sync Terraform state with AWS | `-d` directory |
| `mix terraform.output` | Display Terraform outputs | `-s` short (JSON) |
| `mix terraform.replace` | Replace EC2 instances | `-n` node, `-s` string match, `--all`, `-y` auto-approve |
| `mix terraform.drop` | Destroy all infrastructure | `-y` auto-approve, `--target` (multi) |
| `mix terraform.generate_pem` | Extract PEM from state | `--backend`, `--bucket`, `--region`, `--output-file` |
| `mix terraform.show_password` | Show database password | `--backend`, `--bucket`, `--region` |
| `mix terraform.create_state_bucket` | Create S3 state bucket | |
| `mix terraform.create_state_lock_table` | Create DynamoDB lock table | |
| `mix terraform.drop_state_bucket` | Delete state bucket | |
| `mix terraform.drop_state_lock_table` | Delete lock table | |
| `mix terraform.create_ebs_snapshot` | Snapshot EBS volumes | `--description`, `--include-root`, `--aws-region` |
| `mix terraform.delete_ebs_snapshot` | Delete EBS snapshots | `--snapshot-ids`, `--all`, `--max-age-days` |
| `mix terraform.dump_database` | pg_dump via SSH tunnel | `--format` (custom/text), `--schema-only`, `--output`, `--local-port` |
| `mix terraform.restore_database` | pg_restore via SSH tunnel | `--local`, `--clean`, `--jobs`, `--schema-only` |

## Ansible

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix ansible.build` | Generate Ansible config + playbooks | `-a` auto-pull AWS, `-h` host-only, `-n` new-only, `--no-loki`, `--no-prometheus` |
| `mix ansible.setup` | Initial server configuration | `--parallel`, `--only`/`--except`, `--include-qa` |
| `mix ansible.deploy` | Deploy to instances | `--only`/`--except`, `-t` target-sha, `--qa`, `--parallel`, `--copy-json-env-file` |
| `mix ansible.ping` | Test connectivity | |
| `mix ansible.rollback` | Rollback to previous release | `--select` (interactive) |

## Instance Management

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix deploy_ex.ssh` | SSH into instance | `--root`, `--log`, `--iex`, `--whitelist`, `-i` index, `--qa`, `-l` list |
| `mix deploy_ex.ssh.authorize` | Add SSH key to instances | |
| `mix deploy_ex.restart_app` | Restart app systemd service | `-p` pem |
| `mix deploy_ex.start_app` | Start app service | |
| `mix deploy_ex.stop_app` | Stop app service | |
| `mix deploy_ex.restart_machine` | Reboot EC2 instance | |
| `mix deploy_ex.find_nodes` | Find instances by tags | `--tag` (multi), `--format` (table/json/ids), `--setup-complete` |
| `mix deploy_ex.select_node` | Interactive node selection | |
| `mix deploy_ex.instance.status` | Instance status dashboard | `-e` environment |
| `mix deploy_ex.instance.health` | Instance health checks | `--qa`, `--all` |
| `mix deploy_ex.download_file` | Download file from S3 | |

## QA Nodes

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix deploy_ex.qa` | QA commands overview | |
| `mix deploy_ex.qa.create` | Create QA instance | `-s` sha (required), `--instance-type`, `--attach-lb`, `--skip-setup`, `--skip-deploy` |
| `mix deploy_ex.qa.deploy` | Deploy SHA to QA node | `-s` sha (required) |
| `mix deploy_ex.qa.destroy` | Terminate QA instance | `-i` instance-id, `--all` |
| `mix deploy_ex.qa.list` | List QA nodes | |
| `mix deploy_ex.qa.attach_lb` | Attach to load balancer | |
| `mix deploy_ex.qa.detach_lb` | Detach from load balancer | |
| `mix deploy_ex.qa.cleanup` | Remove terminated nodes from state | |

## Autoscaling

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix deploy_ex.autoscale.refresh` | Trigger ASG instance refresh | `-s` strategy (Rolling/ReplaceRootVolume), `-a` availability, `-w` wait |
| `mix deploy_ex.autoscale.refresh_status` | Check refresh progress | |
| `mix deploy_ex.autoscale.scale` | Set desired capacity | `--desired` |
| `mix deploy_ex.autoscale.status` | Show ASG status | |

## Load Testing

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix deploy_ex.load_test` | Load test commands overview | |
| `mix deploy_ex.load_test.init` | Scaffold k6 test scripts | |
| `mix deploy_ex.load_test.create_instance` | Provision k6 runner EC2 | `--instance-type` |
| `mix deploy_ex.load_test.destroy_instance` | Terminate runner | `-i` instance-id, `--all` |
| `mix deploy_ex.load_test.list` | List active runners | `--json` |
| `mix deploy_ex.load_test.upload` | Upload scripts to runner | `--script` |
| `mix deploy_ex.load_test.exec` | Execute k6 test | `--script`, `--target-url`, `--prometheus-url` |

## Monitoring

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix deploy_ex.load_balancer.health` | Load balancer health status | |
| `mix deploy_ex.grafana.install_dashboard` | Install Grafana dashboard | `--id` (dashboard ID) |

## Utility

| Task | Description | Key Options |
|------|-------------|-------------|
| `mix deploy_ex.export_priv` | Export priv templates to ./deploys/ | |
| `mix deploy_ex.upgrade_priv` | Sync priv changes into ./deploys/ | `--llm-merge` |
| `mix deploy_ex.install_github_action` | Generate CI/CD workflows | |
| `mix deploy_ex.install_migration_script` | Generate migration scripts | |
| `mix deploy_ex.list_available_releases` | List releases in S3 | |
| `mix deploy_ex.list_app_release_history` | Show release history | |
| `mix deploy_ex.view_current_release` | Show current deployed release | |

See also: [Deployment Guide](deployment-guide.md) | [Configuration Guide](configuration-guide.md)
