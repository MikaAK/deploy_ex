# How to Set Up Monitoring

Out of the box, deploy_ex provisions Prometheus, Grafana UI, Grafana Loki, and Sentry (WIP). Each is a separate node type that you can disable at build time with `--no-grafana`, `--no-loki`, `--no-prometheus`, `--no-sentry`.

## Stack Overview

| Component | Default IP | Purpose |
|-----------|-----------|---------|
| `grafana_ui` | (Elastic IP) | UI / dashboards (port 80, default user/pass `admin`/`admin`) |
| `loki_log_aggregator` | `10.0.1.50` | Log aggregator (Loki) |
| `prometheus` | `10.0.1.40` | Metrics TSDB |
| `alloy` (per app node) | n/a | Tails systemd journal, ships to Loki |
| `prometheus_exporter` (per app node) | n/a | Exposes node + app metrics |

## Grafana UI

Out of the box, the `grafana_ui` node serves on port 80 with Loki and Prometheus pre-wired as data sources. Default credentials are `admin` / `admin` — change them on first login.

If `grafana_ui` is provisioned but not running:

```bash
mix ansible.setup --only grafana_ui
```

To use a custom domain, edit `deploys/ansible/roles/grafana_ui/defaults/main.yaml`, change `grafana_ui_domain`, and point an `A` record at the node's Elastic IP.

## Loki (Logging)

Comes with Grafana wired up. If the node isn't running:

```bash
mix ansible.setup --only loki_log_aggregator
```

`alloy` runs on every app node and tails the systemd journal, shipping logs to Loki. To browse logs in Grafana, use the Explore tab with `{InstanceGroup="<app>"}` as the query.

S3-backed retention can be configured via `loki_logger_retention_hours` in `deploys/ansible/group_vars/all.yaml` (default 30 days).

## Prometheus

`prometheus_exporter` runs on every app node and exposes metrics at `:9100`. The `prometheus` node scrapes them via service discovery using the `Group` and `InstanceGroup` tags.

If the Prometheus node isn't running:

```bash
mix ansible.setup --only prometheus
```

The Prometheus service template enables `--web.enable-remote-write-receiver` so external sources (like the k6 load tester) can push metrics directly.

## Installing Grafana Dashboards

Use `mix deploy_ex.grafana.install_dashboard` to install dashboards via the HTTP API. The command auto-discovers the Grafana node by `MonitoringKey` tag, opens an SSH tunnel, and posts the dashboard JSON.

```bash
# From a local file
mix deploy_ex.grafana.install_dashboard --file path/to/dashboard.json

# By grafana.com dashboard ID (downloads latest revision)
mix deploy_ex.grafana.install_dashboard --id 19665

# With custom credentials
mix deploy_ex.grafana.install_dashboard --id 19665 --user admin --password mypassword

# With manual Grafana IP (skips EC2 auto-discovery)
mix deploy_ex.grafana.install_dashboard --file dashboard.json --grafana-ip 54.123.45.67
```

Useful dashboard IDs:
- **k6 Load Testing**: `19665`
- **Node Exporter Full**: `1860`
- **Loki Logs**: `13639`

## Sentry (WIP)

Sentry is currently a work in progress. The Terraform/Ansible provisioning is scaffolded with `--no-sentry` to disable, but the role implementation is incomplete.

## Troubleshooting

If a monitoring service is failing, identify which one and tail its logs:

```bash
mix deploy_ex.ssh <node-type> --log --all -n 50
```

See [Troubleshooting → Monitoring](troubleshooting.md#monitoring) for the full triage table.

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Architecture](../explanation/architecture.md)
