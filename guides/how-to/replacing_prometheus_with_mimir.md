# How to Replace Prometheus with Mimir

deploy_ex ships Mimir as a **push-model** metrics backend, on by default alongside
Prometheus. Every node runs Grafana Alloy, which scrapes only itself (`node_exporter`
on `:9100`, plus the app on `:4050` where one runs) and pushes those series to Mimir
via `prometheus.remote_write`. There is no central scraper, no `ec2_sd`, and no
federation — Mimir's ruler evaluates rule *definitions* identical to the Prometheus
node's (`prometheus_db/templates/prometheus-rules.yaml.j2`, shared via a single
`role_path` reference — never duplicated). Alloy labels its pushed series `job="nodes"`
/ `job="apps"` and attaches `instance`/`instance_id` to match Prometheus's EC2
relabeling, so the shared rules (`NoNodesDiscovered`, `NoAppsDiscovered`, `TargetDown`,
etc.) stay semantically live — but the exact label *values* Alloy derives
(`inventory_hostname`, `instance_id` hostvars) aren't independently diffed against
live Prometheus output this sprint; confirm during step 3 below.

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

**Upgrade consequence:** Mimir is default-ON. If you're upgrading an existing
deploy_ex-managed project (not starting fresh), re-running `mix terraform.build` /
`mix terraform.apply` after upgrading deploy_ex adds a *new* `t3.small` instance +
secondary EBS volume to your Terraform plan (roughly $17/mo at on-demand rates) —
review the plan before applying, or pass `--no-mimir` to opt out until you're ready.

**Delivery to existing `./deploys/` trees:** role files (`priv/ansible/roles/**`,
including `mimir_db` and the Alloy/datasource template changes) and the
`grafana_ui`/`loki_log_aggregator`/`prometheus_db` setup playbooks re-render on every
`mix ansible.build` run, so `--no-mimir` toggles take effect on existing trees too.
`mimir_db.yaml` itself and other static setup files (e.g. `redis.yaml`) are only
delivered on first bootstrap or via `mix deploy_ex.upgrade_priv` — run that if you
don't see `deploys/ansible/setup/mimir_db.yaml` after upgrading deploy_ex.

## The Swap (future cycle — not executed this sprint)

This is a checklist for the cycle that actually cuts over. Each step is safe to do
independently and to pause between. **Apply Terraform before running Ansible** — if
`mimir_db`'s EC2 instance doesn't exist yet, Alloy on every other node will retry its
`remote_write` against a dead private IP until the node comes up.

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
   the ruler has loaded the shared rule groups (quote the URL — `?`/`&` are shell
   metacharacters):
   ```bash
   curl "http://<mimir_db private ip>:8080/prometheus/api/v1/query?query=up"
   curl "http://<mimir_db private ip>:8080/prometheus/api/v1/rules"
   ```

4. **Flip the Grafana default datasource** from "Prometheus Metrics" to "Mimir
   Metrics" (both are already provisioned as `type: prometheus` datasources — see
   `grafana-datasources.yaml.j2`). This is a **manual UI action** — the template
   doesn't set `isDefault`/`uid` on either datasource, so there's nothing to toggle
   via a render flag. The Mimir datasource URL already carries the `/prometheus`
   query-path prefix (`{{ grafana_mimir_url }}/prometheus`), pinned server-side via
   `api.prometheus_http_prefix` in `mimir-config.yaml.j2` so it can't drift with Mimir
   version upgrades. Point dashboards at Mimir; confirm panels render identically.

5. **Point k6 load-test pushes at Mimir.** This requires an actual code change, not
   just a flag or config edit: `DeployEx.K6Runner`/`exec.ex` hardcodes the Prometheus
   remote-write URL (`/api/v1/write` concatenation). `exec.ex` is owned by the LT-FIX
   cross-team effort — coordinate the edit with them rather than changing it here as
   part of this runbook.

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
  Also confirm `mimir-config.yaml.j2`'s `ruler_storage.backend` is `local`, not
  `filesystem` — `filesystem` is a blocks-storage-only backend name and the ruler
  silently serves zero rule groups against it.
- **Play aborts with `AnsibleUndefinedVariable` on a monitoring node** — the Alloy
  journal relabel rule guards `app_name` with `| default('')` specifically because
  monitoring-node plays never set it; if you've customized `alloy_config.alloy.j2`,
  keep that guard.
- **A node isn't pushing metrics** — check `grafana_mimir_url` is defined in
  `deploys/ansible/group_vars/all.yaml` and that the node's `alloy.service` is
  running (`mix deploy_ex.ssh <node-type> --log --all -n 50`).
- **App nodes missing from Mimir** — the `:4050` scrape only renders on hosts where
  `app_name` is set (i.e. app playbooks), by design — monitoring nodes don't run an
  app on that port.
- **`/data is not a mounted filesystem` on mimir_db setup** — the secondary EBS
  volume didn't attach/mount before Ansible ran; re-check the Terraform apply and
  retry setup rather than letting Mimir write to the root volume.

See also: [Monitoring](monitoring.md) | [Mix Tasks Reference](../reference/mix_tasks.md)
