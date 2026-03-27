# How to Manage Autoscaling

## Check Status

```bash
mix deploy_ex.autoscale.status my_app
```

## Scale

```bash
mix deploy_ex.autoscale.scale my_app --desired 3
```

## Instance Refresh

```bash
# Rolling (default) — launch new, then terminate old
mix deploy_ex.autoscale.refresh my_app

# Replace root volume — in-place update
mix deploy_ex.autoscale.refresh my_app --strategy ReplaceRootVolume

# Wait for completion
mix deploy_ex.autoscale.refresh my_app -w
```

### Availability Presets

- `--availability launch-first` — 100% min, 110% max (zero-downtime)
- `--availability terminate-first` — 90% min, 100% max (cost-saving)

## Check Refresh Progress

```bash
mix deploy_ex.autoscale.refresh_status my_app
```

See also: [Mix Tasks Reference](../reference/mix_tasks.md)
