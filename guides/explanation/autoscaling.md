# How Autoscaling Works

deploy_ex provisions AWS Auto Scaling Groups via Terraform. Configuration lives in `deploys/terraform/variables.tf`; runtime levers live in `mix deploy_ex.autoscale.*`. This page explains the mechanics — for the schema see [Terraform Variables](../reference/terraform_variables.md#autoscaling), for commands see the [autoscaling how-to](../how-to/autoscaling.md).

## Source of Truth

Configuration is **declarative** in `variables.tf`. Runtime mutations from `mix deploy_ex.autoscale.scale` go directly to AWS via `UpdateAutoScalingGroup` — they don't touch the file. The `autoscaling.ignore_capacity_changes` flag controls whether those runtime mutations survive the next `terraform.apply`:

| Flag value | Capacity owner | Manual scale persists across apply? |
|------------|---------------|-------------------------------------|
| `false` (default) | `variables.tf` | No — apply resets to declared value |
| `true` | AWS / `mix deploy_ex.autoscale.scale` | Yes — Terraform stops managing capacity after first apply |

Pick `false` if you want capacity declared in code; pick `true` if you scale frequently at runtime and don't want to track capacity in version control.

## Instance Lifecycle

```
1. Launch        — new instance boots from the Launch Template
2. User-data     — cloud-init runs setup scripts inline
3. Discovery     — instance queries existing ASG members or S3 for the current release
4. Download      — pulls release tarball from S3
5. Start         — installs systemd unit, starts the app
6. Health check  — load balancer marks healthy after target health checks pass
7. Cluster join  — libcluster's EC2Tag strategy connects it to peers
```

## Version Consistency

When a new instance launches, it discovers the *correct* release version (not just "latest"):

1. **Query existing instances** via the EC2 API for ASG members
2. **SSH to a peer** and read `/srv/current_release.txt` (written by Ansible on every deploy)
3. **Respect rollbacks** — uses what Ansible deployed, not the newest tarball in S3
4. **Fall back to S3** if no peers exist (enables scale-from-zero)

This avoids the classic ASG bug where a rolled-back release gets undone by a scale-out event.

## Multi-Template Autoscaling

For workloads with predictable schedules (business-hours scale-up, overnight scale-down, weekend off), use the `templates` field in the autoscaling block. Each named template has its own Launch Template and optional `scheduling` actions:

```hcl
templates = {
  business_hours = {
    instance_type = "t3.large"
    min_size = 5; max_size = 20; desired_capacity = 10
    scheduling = [{
      name       = "weekday-up"
      recurrence = "0 8 * * MON-FRI"
      time_zone  = "America/Los_Angeles"
      changes    = { min_size = 5, max_size = 20, desired_capacity = 10 }
    }]
  }
  overnight = {
    instance_type = "t3.small"
    min_size = 1; max_size = 3; desired_capacity = 1
    scheduling = [{
      name       = "weekday-down"
      recurrence = "0 19 * * MON-FRI"
      time_zone  = "America/Los_Angeles"
      changes    = { min_size = 1, max_size = 3, desired_capacity = 1 }
    }]
  }
}
```

`switch_disable_delay_minutes` adds a buffer between schedule transitions so the previous schedule's actions are disabled before the next one's fire — useful when both templates would otherwise overlap and conflict.

Without `templates`, you get one Launch Template using the top-level `instance_type` — most apps need only this.

## IAM Permissions

Autoscaled instances get a dedicated IAM role with:

- `s3:GetObject` / `s3:ListBucket` on the release bucket
- `s3:PutObject` on `release-state/*` (for `current_release.txt` updates)
- `cloudwatch:PutMetricData` for custom metrics
- `ec2:DescribeInstances` for peer discovery
- `ec2:AttachVolume` / `ec2:DetachVolume` / `ec2:DescribeVolumes` (when EBS enabled)
- `logs:*` for CloudWatch Logs
- `ssm:GetParameter` / `ssm:PutParameter` on `/deploy_ex/<env>/*`

## Load Balancing

When `autoscaling.enable === true` and `load_balancer.enable === true`, deploy_ex provisions a Network Load Balancer:

- Instances **register/deregister automatically** with target groups
- Health checks gate traffic — only healthy targets receive requests
- Both HTTP (port 80) and HTTPS (port 443) listeners are supported via `enable_https`

## EBS Volumes

When `ebs.enable_secondary === true` with autoscaling:

- A pool of EBS volumes equal to `max_size` is created (one per potential instance)
- User-data discovers an unattached volume in the same AZ and attaches it
- Filesystem detection — fresh volumes get formatted; otherwise mounted as-is
- Volumes are AZ-pinned — they only attach to instances in the same availability zone

## Limitations

- **Elastic IPs need `preserve_eip_for_single_instance_asg = true`** — otherwise EIP allocation conflicts with ASG-owned ENIs
- **EBS pool size is fixed** at `max_size` — you can't scale-out beyond that without provisioning more volumes
- **EBS volumes are AZ-specific** — uneven AZ load can leave volumes stranded
- **`instance_count` is ignored** when `autoscaling.enable === true`

## Deployment Strategies

Three options when shipping a new release:

### Strategy 1 — Ansible deploy (fast)

```bash
mix deploy_ex.upload
mix ansible.deploy --only my_app
```

- All instances update simultaneously
- Brief unavailability per instance during restart
- Best for: quick fixes, low-traffic windows
- Pro: fast, no instance replacement
- Con: not zero-downtime

### Strategy 2 — Instance refresh (zero-downtime)

```bash
mix deploy_ex.upload
mix deploy_ex.autoscale.refresh my_app --wait
```

- AWS replaces instances gradually, maintaining a healthy floor
- New instances pull from S3 via user-data
- Auto-rollback on health check failure
- Best for: production deploys
- Pro: zero downtime, gradual rollout
- Con: slower; uses extra capacity during refresh

Use `--strategy ReplaceRootVolume` for in-place root-volume swaps when you don't want full instance churn.

### Strategy 3 — Manual scale cycle (test environments)

```bash
mix deploy_ex.upload
mix deploy_ex.autoscale.scale my_app 0
sleep 30
mix deploy_ex.autoscale.scale my_app 3
```

- Forces every instance to be brand new
- Capacity drops to zero during the cycle
- Best for: dev/staging where downtime is fine and you want a guaranteed-clean fleet

## See also

- [How to manage autoscaling](../how-to/autoscaling.md) — runtime commands
- [Terraform variables — autoscaling schema](../reference/terraform_variables.md#autoscaling)
- [Troubleshooting → Autoscaling](../how-to/troubleshooting.md#autoscaling)
- [Clustering](../how-to/clustering.md) — libcluster + EC2Tag
