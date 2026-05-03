# How to Manage Autoscaling

## Check Status

```bash
mix deploy_ex.autoscale.status my_app
```

Shows desired/min/max capacity, instance lifecycle states, and active scaling policies.

## Scale

```bash
mix deploy_ex.autoscale.scale my_app 5            # set desired capacity
mix deploy_ex.autoscale.scale my_app 5 -u         # also raise/lower min/max if needed (--update-limits)
mix deploy_ex.autoscale.scale my_app 0            # scale down to zero
```

## Instance Refresh

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

See also: [Mix Tasks Reference](../reference/mix_tasks.md)
