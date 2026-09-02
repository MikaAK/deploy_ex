# How to Run Load Tests

deploy_ex provides built-in k6 load testing infrastructure using ephemeral runner instances. Test results push to Prometheus via remote-write and visualise in Grafana.

Runner **state** (save/fetch/list/delete) is provider-routed through `DeployEx.Cloud`'s object-store capability, so it works against either provider's configured bucket. Runner **lifecycle** (create/terminate/describe/list) is provider-routed too: under `--provider oci` instances launch via the `oci` CLI into the configured compartment (requires the `:oci` config keys `compartment_id`, `availability_domain`, `subnet_id`, `base_image`, `ssh_public_key` — the key CONTENTS, not a path; `shape` optional with a default). Prometheus discovery remains AWS-only — under `:oci` the exec warns and runs without metrics export.

## Quick Start

```bash
# 1. Scaffold k6 test scripts
mix deploy_ex.load_test.init my_app

# 2. Provision a runner instance
mix deploy_ex.load_test.create_instance

# 3. Upload scripts to the runner
mix deploy_ex.load_test.upload my_app

# 4. Run the test
mix deploy_ex.load_test.exec my_app --target-url http://my-app:4000

# 5. Install the k6 Grafana dashboard (one-time)
mix deploy_ex.grafana.install_dashboard --id 19665

# 6. Tear down the runner when done
mix deploy_ex.load_test.destroy_instance
```

## k6 Script Convention

Scripts live in `deploys/k6/scripts/<app>/`. `load_test.init` creates a template `load_test.js` with configurable stages and a `TARGET_URL` env var. The default template ramps up VUs gradually — edit the `options.stages` block to fit your test profile.

The template also sets `thresholds.http_req_failed` with `abortOnFail: true`, so a run where almost every request fails exits non-zero instead of k6 printing a false "✓ completed". If you're targeting a self-signed cert or a raw IP with no matching TLS hostname, uncomment the `insecureSkipTLSVerify: true` line in `options`.

## Runner Management

Runners are standalone compute instances with k6 pre-installed via cloud-init — today provisioned on AWS EC2 only. Runner state is stored via the active provider's object store at `k6-runners/{instance_id}.json` (AWS: S3; a correctly-configured OCI object store would work the same way once machine provisioning lands). The create command checks for existing runners before launching new ones, so calling it repeatedly is safe — whether reusing or freshly creating a runner, it isn't reported ready until SSH is reachable and `k6 version` succeeds on the instance. If a found runner fails that check, recreate it with `--force`.

```bash
mix deploy_ex.load_test.create_instance --instance-type t3.medium    # default is t3.small
mix deploy_ex.load_test.list                                         # active runners
mix deploy_ex.load_test.list --json                                  # script-friendly output
mix deploy_ex.load_test.destroy_instance                             # single runner: no flag needed
mix deploy_ex.load_test.destroy_instance --instance-id i-0abc123     # multiple runners: target one
mix deploy_ex.load_test.destroy_instance --all --force                # multiple runners: destroy all
```

If more than one runner exists, `destroy_instance` refuses to guess — pass `--instance-id`/`-i` or `--all`.

## Prometheus Remote Write

The Prometheus service template enables `--web.enable-remote-write-receiver`, so k6 pushes metrics straight in. Nodes deployed from an OLDER template may still run a unit without the flag — the push then gets HTTP 404 from `/api/v1/write`; re-run the prometheus setup playbook (or add the flag to the unit and restart) to enable it. By default `mix deploy_ex.load_test.exec` discovers the running prometheus node's private IP by tag and writes to `http://<discovered-ip>:9090/api/v1/write`; if no prometheus node is found, the test runs without metrics export. Override with `--prometheus-url` if your Prometheus runs elsewhere:

```bash
mix deploy_ex.load_test.exec my_app \
  --target-url http://my-app:4000 \
  --prometheus-url http://prom.internal:9090
```

Once metrics are flowing, install dashboard ID `19665` from grafana.com to get k6's standard visualisations:

```bash
mix deploy_ex.grafana.install_dashboard --id 19665
```

## Tips

- Use `--target-url` with the **internal** load balancer URL or a private IP — runners share the VPC with your app, so external DNS is a wasted hop
- Node private IPs drift across replacements — don't hardcode one in a script or doc. Discover the current IP with `mix deploy_ex.find_nodes`, then point `--target-url` at it
- For sustained tests, scale the runner up with `--instance-type` — `t3.large` is fine for short bursts but a `c5.xlarge` is more honest about server-side bottlenecks
- Don't forget `mix deploy_ex.load_test.destroy_instance` when you're done — runners cost money

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Monitoring](monitoring.md)
