# How to Set Up Monitoring

Out of the box, deploy_ex provisions Prometheus, Mimir, Grafana UI, Grafana Loki, and Sentry. Each is a separate node type that you can disable at build time with `--no-grafana`, `--no-loki`, `--no-prometheus`, `--no-mimir`, `--no-sentry`.

## Stack Overview

| Component | AZ / IP | Purpose |
|-----------|---------|---------|
| `grafana_ui` | AZ-pinned (Elastic IP) | UI / dashboards (port 80, default user/pass `admin`/`admin`) |
| `loki_log_aggregator` | AZ-pinned (DHCP) | Log aggregator (Loki) |
| `prometheus` | AZ-pinned (DHCP) | Metrics TSDB (pull, via `ec2_sd`) |
| `mimir_db` | AZ-pinned (DHCP) | Metrics TSDB + ruler (push, via Alloy `remote_write`) |
| `redis` | AZ-pinned (DHCP) | Session/cache store |
| `sentry` | AZ-pinned (DHCP) | Error monitoring (`getsentry/self-hosted`, private VPC only) |
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

## Sentry

Self-hosted error monitoring (`getsentry/self-hosted`, pinned release — see `deploys/ansible/roles/sentry_server/defaults/main.yaml` for the current tag). Provisioned by default; disable at build time with `--no-sentry`.

### Sizing and profile

Runs upstream's **`errors-only`** compose profile (error monitoring, per the original ask) on a `t3.large` instance (2 vCPU / 8GB) with a 64GB secondary EBS volume for Postgres/Kafka/ClickHouse data. Upstream's `install.sh` hard-exits in `check-minimum-requirements.sh` when resources are below its floor for the *active* profile:

| Profile | Floor | `t3.large` (2 vCPU / 8GB) |
|---|---|---|
| `errors-only` (default here) | 2 vCPU / 7000MB | Clears it |
| `feature-complete` (performance monitoring, session replay, etc.) | 4 vCPU / 14000MB | Does **not** clear it — a deterministic preflight exit, not an occasional failure |

**To upgrade to `feature-complete`:**
1. Raise `instance_type` in `terraform.build.ex`'s `terraform_sentry_variables/1` to something ≥ 4 vCPU / 14GB (e.g. `t3.xlarge`).
2. Flip `COMPOSE_PROFILES=errors-only` → `COMPOSE_PROFILES=feature-complete` in `priv/ansible/roles/sentry_server/templates/env.j2`.
3. `mix terraform.apply --target 'module.ec2_instance["sentry"]'`, then re-run `mix ansible.setup --only sentry`.

Disk usage under `errors-only` is meaningfully lower than `feature-complete` (fewer services, no performance/replay event volume) — `SENTRY_EVENT_RETENTION_DAYS` (`.env`, default 90) is still the main lever if the 64GB secondary volume fills up; lower it before resizing the volume.

### Access — private VPC only

The Sentry web service binds to the node's private VPC address (`SENTRY_BIND` in `.env`, not loopback) — reachability is enforced by the security group, the same convention as the loki/prometheus nodes, not by binding to `127.0.0.1`. There is no public exposure and no Let's Encrypt cert this cycle.

```bash
mix deploy_ex.ssh.authorize                              # allowlist your IP for SSH (port 22 is allowlist-only)
mix deploy_ex.find_nodes --tag MonitoringKey=sentry       # find the node's IP
ssh -i deploys/terraform/*.pem -L 9000:10.0.1.80:9000 admin@<sentry-node-ip>
```

The `-L` remote address (the node's own bound VPC address, on port 9000) is resolved by the SSH server (the sentry node), not your machine. Then browse `http://localhost:9000` locally. `group_vars/all.yaml`'s `sentry_url` is the same address — it's what the Sentry container uses to build links back to the UI, and is also what the tunnel targets.

**Security group note:** a freshly-generated deploy_ex security group has no rule allowing traffic between members of the group itself, and no rule for port 9000 — only `http-80-tcp`/`https-443-tcp` from `0.0.0.0/0` plus the dynamic SSH allowlist. cfx's live security group currently has an all-protocol self-referencing rule (infrastructure drift, not shipped by these templates) which is why the tunnel already works there. New consumers need an equivalent intra-SG (or port-9000-scoped) ingress rule added by hand — **this sprint does not template any security group change.**

If the node isn't running:

```bash
mix ansible.setup --only sentry
```

### Idempotence

- **Install**: guarded by a marker file (`.deploy_ex_installed_<version>` in the install directory) — re-running `ansible.setup` on a healthy node does not re-run `install.sh` (a full image pull + DB migration). Bumping `sentry_release_version` removes the guard for the new version and re-runs the install.
- **`.env`**: getsentry/self-hosted git-tracks `.env` with real content; deploy_ex's `env.j2` overwrites it every run. The `git` clone task uses `force: true` so a re-run's checkout doesn't abort on "Local modifications exist" — it resets the tracked `.env` and then `env.j2` re-renders the private-bind override immediately after. Untracked files (`sentry/config.yml`, the install marker) are unaffected by the forced checkout.
- **`config.yml`**: deploy_ex never templates the whole file — only `system.url-prefix` is patched in place (idempotent `lineinfile`, regex-matched) *after* `install.sh` runs. `install.sh` is what creates `config.yml` from upstream's example and writes `system.secret-key` on first install; pre-creating the file would skip both steps and every re-run would wipe the generated key.

## Troubleshooting

If a monitoring service is failing, identify which one and tail its logs:

```bash
mix deploy_ex.ssh <node-type> --log --all -n 50
```

See [Troubleshooting → Monitoring](troubleshooting.md#monitoring) for the full triage table.

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Architecture](../explanation/architecture.md)
