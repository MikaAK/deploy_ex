# How to Replace Prometheus with Mimir

deploy_ex ships Mimir as a **push-model** metrics backend, on by default alongside
Prometheus. Every node runs Grafana Alloy, which scrapes only itself (`node_exporter`
on `:9100`, plus the app on `:4050` where one runs) and pushes those series to Mimir
via `prometheus.remote_write`. There is no central scraper, no `ec2_sd`, and no
federation — Mimir's ruler evaluates the exact same alert rules as the Prometheus
node (`prometheus_db/templates/prometheus-rules.yaml.j2`, shared via a single
`role_path` reference — never duplicated).

This is additive this cycle: **Prometheus keeps running untouched.** Nothing in this
guide is required to run deploy_ex — Mimir provisions, and the two backends coexist,
until you deliberately execute the swap below.

## Stack Overview

| Component | Default IP | Purpose |
|-----------|-----------|---------|
| `mimir_db` | `10.0.1.70` | Push-based metrics TSDB + ruler (monolithic mode) |
| `prometheus_db` | `10.0.1.40` | Pull-based metrics TSDB (unchanged, still scraping) |
| `alloy` (every node) | n/a | Tails the journal (Loki) **and** scrapes+pushes local metrics (Mimir) |

Disable Mimir at build time with `--no-mimir` if you don't want the node provisioned
yet.

## The Swap (future cycle — not executed this sprint)

This is a checklist for the cycle that actually cuts over. Each step is safe to do
independently and to pause between.

1. **Enable Mimir** (default — no flag needed unless you previously passed `--no-mimir`):
   ```bash
   mix terraform.build
   mix terraform.apply
   mix ansible.build
   ```

2. **Roll Alloy everywhere.** The `grafana_ui`, `loki_log_aggregator`, `prometheus_db`,
   and `mimir_db` setup playbooks all carry the `grafana_alloy` role now, so every
   monitoring node — not just app nodes — starts pushing its own `node_exporter`
   metrics to Mimir:
   ```bash
   mix ansible.setup --only grafana_ui,loki_log_aggregator,prometheus_db,mimir_db
   mix ansible.setup   # app nodes, if not already rolled
   ```

3. **Verify series parity.** Query Mimir's Prometheus-compatible API and confirm the
   same `up`/`node_cpu_seconds_total` series exist there as in Prometheus, and that
   the ruler has loaded the shared rule groups:
   ```bash
   curl http://<mimir_db private ip>:8080/prometheus/api/v1/query?query=up
   curl http://<mimir_db private ip>:8080/prometheus/api/v1/rules
   ```

4. **Flip the Grafana default datasource** from "Prometheus Metrics" to "Mimir
   Metrics" (both are already provisioned as `type: prometheus` datasources — see
   `grafana-datasources.yaml.j2`). Point dashboards at Mimir; confirm panels render
   identically.

5. **Point k6 load-test pushes at Mimir.** `k6`'s remote-write target
   (`DeployEx.K6Runner`/`exec.ex`) currently pushes to Prometheus — repoint it at
   `{{ grafana_mimir_url }}/api/v1/push` as part of this same cutover, not before.

6. **Tear down Prometheus**, only once every consumer of it (dashboards, k6, alerts)
   has been confirmed against Mimir:
   ```bash
   mix terraform.build --no-prometheus
   mix terraform.apply
   mix terraform.replace -n prometheus_db   # or drop the node manually
   ```

## Troubleshooting

- **Mimir ruler shows no rule groups** — confirm `/data/mimir/rules/anonymous/rules.yaml`
  exists on the `mimir_db` node and matches
  `deploys/ansible/roles/prometheus_db/templates/prometheus-rules.yaml.j2` byte for
  byte (it's templated from that exact file — there is no separate copy to drift).
- **A node isn't pushing metrics** — check `grafana_mimir_url` is defined in
  `deploys/ansible/group_vars/all.yaml` and that the node's `alloy.service` is
  running (`mix deploy_ex.ssh <node-type> --log --all -n 50`).
- **App nodes missing from Mimir** — the `:4050` scrape only renders on hosts where
  `app_name` is set (i.e. app playbooks), by design — monitoring nodes don't run an
  app on that port.

See also: [Monitoring](monitoring.md) | [Mix Tasks Reference](../reference/mix_tasks.md)
