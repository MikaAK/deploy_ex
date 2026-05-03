# How to Manage Autoscaling

Autoscaling configuration lives in `deploys/terraform/variables.tf`. **Edit the file, run `mix terraform.apply`** — that's the standard workflow. The `mix deploy_ex.autoscale.*` commands are runtime levers (manual override, instance refresh, status) that operate against an already-configured ASG.

## Configure (Terraform)

Add an `autoscaling` block to your app's entry in `variables.tf`:

```hcl
my_app_project = {
  my_app = {
    instance_type = "t3.small"

    autoscaling = {
      enable                  = true
      min_size                = 2
      max_size                = 10
      desired_capacity        = 3
      cpu_target_percent      = 60
      scale_in_cooldown       = 300
      scale_out_cooldown      = 300
      ignore_capacity_changes = false       # see below
    }

    load_balancer = {
      enable        = true
      port          = 80
      instance_port = 4000
      health_check  = { path = "/health" }
    }
  }
}
```

Then:

```bash
mix terraform.plan                # preview the ASG / Launch Template / target group
mix terraform.apply               # add -y to skip confirmation
```

For the full schema (templates, scheduled scaling, `ignore_capacity_changes` semantics) see [Terraform Variables](../reference/terraform_variables.md#autoscaling).

### Important: `ignore_capacity_changes`

Decide whether `variables.tf` or AWS owns the **runtime** desired capacity:

- `false` (default): every `terraform.apply` resets `desired_capacity` to whatever's in the file. `mix deploy_ex.autoscale.scale` becomes a temporary override that any future apply will undo.
- `true`: Terraform sets capacity once, then ignores drift. `mix deploy_ex.autoscale.scale` and CPU autoscaling become the only ways capacity changes thereafter.

Pick one. Don't flip it mid-flight.

## Status Commands

```bash
mix deploy_ex.autoscale.status my_app             # ASG capacity, lifecycle states, AZs, scaling policies
mix deploy_ex.instance.status my_app              # detailed: ASG + instances + LB health + tags
```

## Runtime Override (Manual Scale)

Useful for one-off events: a marketing burst, a maintenance window, scale-to-zero before tearing down.

```bash
mix deploy_ex.autoscale.scale my_app 5            # set desired capacity to 5
mix deploy_ex.autoscale.scale my_app 5 -u         # also widen min/max if 5 is outside the range (--update-limits)
mix deploy_ex.autoscale.scale my_app 0            # scale to zero (stops all instances)
```

This calls `UpdateAutoScalingGroup` directly — it doesn't touch `variables.tf`. If `ignore_capacity_changes = false`, the next `terraform.apply` will revert. **Treat this as a temporary lever**; if you need a permanent change, edit `variables.tf` and apply.

## Instance Refresh (rolling deploy)

Replace every running instance with a fresh one. AWS stages it gradually based on the availability preset:

```bash
mix deploy_ex.autoscale.refresh my_app                                      # rolling (default)
mix deploy_ex.autoscale.refresh my_app -s ReplaceRootVolume                 # in-place root-volume swap
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

## Track an Active Refresh

```bash
mix deploy_ex.autoscale.refresh_status my_app             # active refresh only
mix deploy_ex.autoscale.refresh_status my_app --all       # full history
```

## Connecting to Autoscaled Instances

Instance count is dynamic — `mix deploy_ex.ssh` provides selection helpers:

```bash
mix deploy_ex.ssh my_app --list                    # list instances with indices and IPs
mix deploy_ex.ssh my_app --index 0                 # connect to instance at index 0
mix deploy_ex.ssh my_app                           # interactive picker
mix deploy_ex.ssh my_app --index 1 --log
mix deploy_ex.ssh my_app --index 2 --iex
```

See [Connecting to Nodes](connecting_to_nodes.md) for the eval pattern and shell aliases.

## Picking a Deployment Strategy

When shipping a new release to autoscaled instances, you have three options. Each has tradeoffs — see [Autoscaling explanation → Deployment Strategies](../explanation/autoscaling.md#deployment-strategies) for full detail.

| Strategy | Command | When |
|----------|---------|------|
| **Ansible deploy** | `mix deploy_ex.upload && mix ansible.deploy --only my_app` | Fast updates, low traffic |
| **Instance refresh** | `mix deploy_ex.upload && mix deploy_ex.autoscale.refresh my_app --wait` | Production, zero-downtime |
| **Manual scale cycle** | `scale 0 → wait → scale N` | Test environments only |

See also: [Terraform Variables — autoscaling schema](../reference/terraform_variables.md#autoscaling) | [Mix Tasks Reference](../reference/mix_tasks.md) | [Troubleshooting → Autoscaling](troubleshooting.md#autoscaling)
