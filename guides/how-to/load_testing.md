# How to Run Load Tests

deploy_ex provides built-in k6 load testing infrastructure using ephemeral EC2 runner instances. Test results push to Prometheus via remote-write and visualise in Grafana.

## Quick Start

```bash
# 1. Scaffold k6 test scripts
mix deploy_ex.load_test.init my_app

# 2. Provision a runner instance
mix deploy_ex.load_test.create_instance

# 3. Upload scripts to the runner
mix deploy_ex.load_test.upload --script load_tests/my_app/load_test.js

# 4. Run the test
mix deploy_ex.load_test.exec --script load_test.js --target-url http://my-app:4000

# 5. Install the k6 Grafana dashboard (one-time)
mix deploy_ex.grafana.install_dashboard --id 19665

# 6. Tear down the runner when done
mix deploy_ex.load_test.destroy_instance
```

## k6 Script Convention

Scripts live in `deploys/k6/scripts/<app>/`. `load_test.init` creates a template `load_test.js` with configurable stages and a `TARGET_URL` env var. The default template ramps up VUs gradually — edit the `options.stages` block to fit your test profile.

## Runner Management

Runners are standalone EC2 instances with k6 pre-installed via cloud-init. State is stored in S3 at `k6-runners/{instance_id}.json`. The create command checks for existing runners before launching new ones, so calling it repeatedly is safe.

```bash
mix deploy_ex.load_test.create_instance --instance-type t3.medium    # default is t3.large
mix deploy_ex.load_test.list                                         # active runners
mix deploy_ex.load_test.list --json                                  # script-friendly output
mix deploy_ex.load_test.destroy_instance                             # interactive picker
mix deploy_ex.load_test.destroy_instance --all --force               # nuke them all
```

## Prometheus Remote Write

The Prometheus service template enables `--web.enable-remote-write-receiver`, so k6 pushes metrics straight in. By default `mix deploy_ex.load_test.exec` writes to `http://10.0.1.40:9090/api/v1/write` — override with `--prometheus-url` if your Prometheus runs elsewhere:

```bash
mix deploy_ex.load_test.exec --script load_test.js \
  --target-url http://my-app:4000 \
  --prometheus-url http://prom.internal:9090/api/v1/write
```

Once metrics are flowing, install dashboard ID `19665` from grafana.com to get k6's standard visualisations:

```bash
mix deploy_ex.grafana.install_dashboard --id 19665
```

## Tips

- Use `--target-url` with the **internal** load balancer URL or a private IP — runners share the VPC with your app, so external DNS is a wasted hop
- For sustained tests, scale the runner up with `--instance-type` — `t3.large` is fine for short bursts but a `c5.xlarge` is more honest about server-side bottlenecks
- Don't forget `mix deploy_ex.load_test.destroy_instance` when you're done — runners cost money

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Monitoring](monitoring.md)
