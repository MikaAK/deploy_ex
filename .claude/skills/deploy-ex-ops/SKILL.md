---
name: deploy-ex-ops
description: "Use when executing deploy_ex commands to operate on running infrastructure — deploying releases, uploading to S3, running Ansible deploys, managing QA nodes, autoscaling EC2 instances, running k6 load tests, SSH-ing into instances, checking instance health, viewing logs, connecting to remote IEx, rolling back releases, restarting apps, or checking what's currently deployed. This is for RUNNING existing deploy_ex mix tasks, not for writing new code or generating infrastructure files. Triggers on: deploy to production, upload release, rollback, QA node create/destroy, scale up/down, SSH into server, app is down, check health, restart app, view logs, iex console, load test, what's deployed, ping ansible hosts. Use this even without mentioning deploy_ex — if someone wants to deploy an Elixir app, check instance status, or restart a service in this project, this skill applies."
---

# deploy_ex Operations

Guide for running deploy_ex deployment operations on Elixir projects targeting AWS.

## Quick Reference

### Release Cycle
```bash
mix deploy_ex.release [--only app1] [--force]   # build (change detection)
mix deploy_ex.upload [--parallel]                 # upload to S3
mix ansible.deploy [--only app1]                  # deploy to EC2
```

### First-time Setup
```bash
mix deploy_ex.full_setup -yak    # -y auto-approve, -a auto-pull AWS creds, -k skip-deploy
mix deploy_ex.install_github_action
```

### Rollback
```bash
mix ansible.rollback my_app [--select]   # --select for interactive history picker
```

## Workflows

### Building and Deploying a Release

deploy_ex detects which apps changed since the last release using git diff, mix.lock changes, and the mix deps.tree. Only changed apps get rebuilt.

1. `mix deploy_ex.release` — builds releases for changed apps. For Phoenix apps, runs the full asset pipeline (npm, esbuild, sass, tailwind, phx.digest) automatically.
2. `mix deploy_ex.upload` — uploads `.tar.gz` artifacts to S3. QA releases auto-detected from `qa/*` or `qa-*` branch names.
3. `mix ansible.deploy` — runs Ansible playbooks against EC2 instances. Use `--target-sha abc1234` to deploy a specific SHA.

Force rebuild all: `mix deploy_ex.release --force`
Target specific apps: `--only app1 --only app2` or `--except app3`

### QA Nodes

Ephemeral EC2 instances for testing specific SHAs:

```bash
mix deploy_ex.qa.create my_app --sha abc1234 [--attach-lb]
mix deploy_ex.qa.deploy my_app --sha def5678       # redeploy different SHA
mix deploy_ex.qa.attach_lb my_app                   # route traffic
mix deploy_ex.qa.detach_lb my_app                   # stop traffic
mix deploy_ex.qa.destroy my_app [--all]              # clean up
mix deploy_ex.qa.list                                # list nodes
mix deploy_ex.qa.cleanup                             # remove terminated from state
```

QA nodes reuse app-specific AMIs when available (skipping Ansible setup). State persisted to S3 at `qa-nodes/{app_name}/{instance_id}.json`.

### Autoscaling

```bash
mix deploy_ex.autoscale.status my_app
mix deploy_ex.autoscale.scale my_app --desired 3
mix deploy_ex.autoscale.refresh my_app [-s Rolling] [-a launch-first] [-w]
mix deploy_ex.autoscale.refresh_status my_app
```

Strategies: `Rolling` (default, launch-then-terminate) or `ReplaceRootVolume` (in-place).
Availability presets: `launch-first` (100%/110%, zero-downtime) or `terminate-first` (90%/100%, cost-saving).

### Load Testing (k6)

```bash
mix deploy_ex.load_test.init my_app
mix deploy_ex.load_test.create_instance [--instance-type t3.small]
mix deploy_ex.load_test.upload --script load_test.js
mix deploy_ex.load_test.exec --target-url http://... [--prometheus-url http://...]
mix deploy_ex.load_test.destroy_instance
```

### Connecting to Instances

```bash
mix deploy_ex.ssh my_app              # interactive SSH
mix deploy_ex.ssh my_app --root       # SSH as root
mix deploy_ex.ssh my_app --log        # stream app logs (journalctl)
mix deploy_ex.ssh my_app --iex        # remote IEx console
mix deploy_ex.ssh.authorize my_app    # add your SSH key
```

### Instance Management

```bash
mix deploy_ex.instance.status my_app [-e prod]
mix deploy_ex.instance.health [--qa] [--all]
mix deploy_ex.restart_app my_app
mix deploy_ex.start_app my_app / mix deploy_ex.stop_app my_app
mix deploy_ex.restart_machine my_app
mix deploy_ex.find_nodes [--tag key=value] [--format table|json|ids]
```

### Monitoring

```bash
mix deploy_ex.load_balancer.health my_app
mix deploy_ex.grafana.install_dashboard --id 19665    # k6 dashboard
mix deploy_ex.view_current_release my_app
mix deploy_ex.list_available_releases
mix deploy_ex.list_app_release_history my_app
```

## Universal Options

Most tasks accept: `--only` (multi), `--except` (multi), `--force`/`-f`, `--quiet`/`-q`, `--no-tui`

## Important Context

- All tasks require valid AWS credentials (env vars, AWS_PROFILE, or instance role)
- Tasks validate project type first via `DeployExHelpers.check_valid_project()` — works for both umbrella and single-app projects
- Destructive operations (drop, destroy) prompt for confirmation unless `--force` or `--auto-approve`
- TUI is auto-disabled in CI or when stdin isn't a TTY
- Release artifacts stored in S3 at `{app}/{timestamp}-{sha}-{filename}.tar.gz`

For full task reference, read `docs/api-reference.md`.
For configuration, read `docs/configuration-guide.md`.
