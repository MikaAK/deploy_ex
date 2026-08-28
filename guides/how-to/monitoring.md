# How to Set Up Monitoring

Out of the box, deploy_ex provisions Prometheus, Mimir, Grafana UI, Grafana Loki, and Sentry (WIP). Each is a separate node type that you can disable at build time with `--no-grafana`, `--no-loki`, `--no-prometheus`, `--no-mimir`, `--no-sentry`.

## Stack Overview

| Component | AZ / IP | Purpose |
|-----------|---------|---------|
| `grafana_ui` | AZ-pinned (Elastic IP) | UI / dashboards (port 80, default user/pass `admin`/`admin`) |
| `loki_log_aggregator` | AZ-pinned (DHCP) | Log aggregator (Loki) |
| `prometheus` | AZ-pinned (DHCP) | Metrics TSDB (pull, via `ec2_sd`) |
| `mimir_db` | AZ-pinned (DHCP) | Metrics TSDB + ruler (push, via Alloy `remote_write`) |
| `redis` | AZ-pinned (DHCP) | Session/cache store |
| `sentry` | AZ-pinned (DHCP) | Error tracking (WIP) |
| `alloy` (every node) | n/a | Tails systemd journal (ships to Loki); scrapes `node_exporter`/app locally and pushes to Mimir |
| `prometheus_exporter` (per app node) | n/a | Exposes node + app metrics |

## DHCP + shared AZ pin — no more fixed private IPs

The monitoring/DB stock var blocks (`<app>_redis`, `sentry`, `loki_aggregator`, `grafana_ui`,
`prometheus_db`, `mimir_db`) no longer ship a fixed `private_ip`. `ec2.tf.eex` wires every instance
to `module.vpc.public_subnets`, while the old fixed IPs (`10.0.1.40`/`.50`/`.60`/`.70`) sat in the
*private* subnet range — a stock render was deterministically un-applyable
(`InvalidParameterValue: Address ... does not fall within the subnet's address range`).

Instead, every one of these blocks sets `instance_availability_zone` to the **same** shared
value, so all six peers land in one AZ by construction (their private IPs are DHCP-assigned).
The shared default is the `mix terraform.build --aws-region`'s "a" zone (e.g. `us-west-2` →
`us-west-2a`); override it explicitly with `mix terraform.build --availability-zone us-east-1c`
or the `:aws_availability_zone` application env key.

Because these IPs are no longer known at render time, `deploys/ansible/group_vars/all.yaml`'s
`grafana_loki_url`, `grafana_prometheus_url`, and `grafana_mimir_url` render as
`http://FILL_IN_AFTER_FIRST_APPLY:<port>` placeholders. After your first `mix terraform.apply`,
discover the real address and fill it in:

```bash
mix deploy_ex.find_nodes --tag MonitoringKey=loki_logger
mix deploy_ex.find_nodes --tag MonitoringKey=prometheus_db
mix deploy_ex.find_nodes --tag MonitoringKey=mimir_db
```

**Upgrade note:** if your `deploys/terraform/variables.tf` still carries an old fixed `private_ip`
for one of these nodes, remove it (or replace it with `instance_availability_zone`) before
applying — the fixed IP will fail to apply once the node is on a public subnet. Re-rendering with
`mix terraform.build --force` regenerates the stock blocks with the new convention, but
`--force` OVERWRITES your file — diff before accepting (see the EBS hazard note below).

## Upgrading — secondary EBS volumes attach correctly (all monitoring/DB nodes, including mimir_db)

Prior to this fix, the `<app>_redis`, `loki_aggregator`, `grafana_ui`, `prometheus_db`, and
`mimir_db` variable blocks used a flat `enable_ebs` / `instance_ebs_secondary_size` pair that the `ebs`
schema in `variables.tf` silently ignores (`tofu validate` warns "Object attribute is ignored").
No secondary EBS volume was ever created for these nodes from a stock render.

After re-rendering with `mix terraform.build` (or `mix deploy_ex.upgrade_priv`), these blocks
use the correct nested form:

```hcl
ebs = {
  enable_secondary = true
  secondary_size   = 16
}
```

Your next `mix terraform.plan` will show a NEW secondary EBS volume being created for each of
these nodes — this is expected, not a regression. The real upgrade hazard is the rendered
`deploys/terraform/variables.tf`: a re-render with `--force` OVERWRITES it, so a consumer who
hand-customized that file must diff before accepting. Hand-edited `tfvars` that already use the
nested `ebs = { ... }` form (as recommended for production) are unaffected.

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

## Mimir (Metrics, Push-Based)

Mimir is provisioned by default alongside Prometheus — additive this cycle, no
teardown. Every node (not just app nodes) runs Alloy, which scrapes only itself
(`node_exporter` on `:9100`, plus the app on `:4050` where one runs) and
`remote_write`s to Mimir with `job="nodes"`/`job="apps"` labels plus `instance`/
`instance_id`, matching Prometheus's EC2 relabeling. Mimir's ruler evaluates the
same rule *definitions* as Prometheus, templated from the single shared source
(`prometheus_db/templates/prometheus-rules.yaml.j2` — never duplicated).

If the Mimir node isn't running:

```bash
mix ansible.setup --only mimir_db
```

`deploys/ansible/setup/mimir_db.yaml` is a static file — if you upgraded deploy_ex and
don't see it in an existing tree, run `mix deploy_ex.upgrade_priv` first (see
[Replacing Prometheus with Mimir](replacing_prometheus_with_mimir.md) for the full
delivery-mechanism breakdown across the monitoring setup playbooks).

Disable it entirely with `mix terraform.build --no-mimir`.

To actually cut over from Prometheus to Mimir (verify parity, flip the Grafana
datasource, tear down Prometheus), see
[Replacing Prometheus with Mimir](replacing_prometheus_with_mimir.md) — that swap is
a deliberate, future action, not something this provisioning does automatically.

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
