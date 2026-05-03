# How to Manage Autoscaling

Day-to-day commands for autoscaled apps. See [Autoscaling explanation](../explanation/autoscaling.md) for how it works under the hood, and [Terraform variables](../reference/terraform_variables.md) for the config schema.

## Enable Autoscaling

Edit `deploys/terraform/variables.tf`:

```hcl
my_app_project = {
  my_app = {
    instance_type = "t3.small"
    autoscaling = {
      enable             = true
      min_size           = 1
      max_size           = 5
      desired_capacity   = 2
      cpu_target_percent = 60
    }
    load_balancer = { enable = true, port = 80, instance_port = 4000 }
  }
}
```

Then `mix terraform.apply`. See [Terraform Variables](../reference/terraform_variables.md) for every field.

## Check Status

```bash
mix deploy_ex.autoscale.status my_app
mix deploy_ex.instance.status my_app          # detailed: ASG + instances + LB health + tags
```

`autoscale.status` shows desired/min/max, instance lifecycle states, AZs, and active scaling policies. `instance.status` adds full per-instance breakdown including LB target group health.

## Scale

```bash
mix deploy_ex.autoscale.scale my_app 5            # set desired capacity
mix deploy_ex.autoscale.scale my_app 5 -u         # also raise/lower min/max if needed (--update-limits)
mix deploy_ex.autoscale.scale my_app 0            # scale to zero (stops all instances)
```

AWS rejects values outside `[min_size, max_size]` — use `-u` to widen the bounds in the same call. Terraform ignores `desired_capacity` drift, so manual scaling sticks.

## Instance Refresh (rolling deploy)

```bash
mix deploy_ex.autoscale.refresh my_app                                      # rolling (default)
mix deploy_ex.autoscale.refresh my_app -s ReplaceRootVolume                 # in-place root volume swap
mix deploy_ex.autoscale.refresh my_app -w                                   # wait for completion
mix deploy_ex.autoscale.refresh my_app --skip-matching                      # skip instances already on the desired AMI
mix deploy_ex.autoscale.refresh my_app --instance-warmup 60                 # warmup seconds (default 300)
```

### Availability presets

- `--availability launch-first` — min 100% / max 110% (zero-downtime)
- `--availability terminate-first` — min 90% / max 100% (cost-saving)

Or set them explicitly:

```bash
mix deploy_ex.autoscale.refresh my_app --min-healthy-percentage 100 --max-healthy-percentage 110
```

## Track a Refresh

```bash
mix deploy_ex.autoscale.refresh_status my_app             # active refresh only
mix deploy_ex.autoscale.refresh_status my_app --all       # full refresh history
```

## Connecting to Autoscaled Instances

Instance count is dynamic, so `mix deploy_ex.ssh` provides selection helpers:

```bash
mix deploy_ex.ssh my_app --list                    # list instances with indices and IPs
mix deploy_ex.ssh my_app --index 0                 # connect to instance at index 0
mix deploy_ex.ssh my_app                           # interactive picker (or random with -s)
mix deploy_ex.ssh my_app --index 1 --log
mix deploy_ex.ssh my_app --index 2 --iex
```

## Picking a Deployment Strategy

Three options when shipping a new release:

| Strategy | Command | When |
|----------|---------|------|
| Ansible deploy | `mix deploy_ex.upload && mix ansible.deploy --only my_app` | Fast updates, low traffic |
| Instance refresh | `mix deploy_ex.upload && mix deploy_ex.autoscale.refresh my_app --wait` | Production, zero-downtime |
| Manual scale cycle | `scale 0 → wait → scale N` | Test environments |

See [Autoscaling explanation → Deployment Strategies](../explanation/autoscaling.md#deployment-strategies) for tradeoffs.

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Troubleshooting → Autoscaling](troubleshooting.md#autoscaling)
