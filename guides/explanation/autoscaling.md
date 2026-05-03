# How Autoscaling Works

deploy_ex provisions AWS Auto Scaling Groups with CPU-target scaling, dynamic EBS volume attachment, automatic release discovery, and Network Load Balancer integration. This page explains the mechanics — for commands, see the [autoscaling how-to](../how-to/autoscaling.md); for config, see [terraform variables](../reference/terraform_variables.md).

## Configuration

Enable autoscaling per app in `deploys/terraform/variables.tf`:

```hcl
my_app_project = {
  my_app = {
    name          = "My App"
    instance_type = "t3.nano"

    autoscaling = {
      enable             = true
      min_size           = 1
      max_size           = 5
      desired_capacity   = 2
      cpu_target_percent = 60
      scale_in_cooldown  = 300
      scale_out_cooldown = 300
    }

    load_balancer = {
      enable        = true
      port          = 80
      instance_port = 4000
      health_check = {
        path     = "/health"
        protocol = "HTTP"
      }
    }

    # EBS volumes attach dynamically; pool size = max_size
    ebs = {
      enable_secondary = true
      secondary_size   = 32
    }
  }
}
```

| Field | Purpose |
|-------|---------|
| `enable` | Turn autoscaling on for this app |
| `min_size` | Hard floor — ASG never goes below this |
| `max_size` | Hard ceiling — also defines EBS volume pool size |
| `desired_capacity` | Initial instance count (Terraform ignores drift on this — see below) |
| `cpu_target_percent` | Target average CPU; scaling tries to maintain it |
| `scale_in_cooldown` | Seconds after a scale-in before another can fire |
| `scale_out_cooldown` | Seconds after a scale-out before another can fire |

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
- Filesystem detection — if the volume is fresh, it's formatted; otherwise mounted as-is
- Volumes are AZ-pinned — they only attach to instances in the same availability zone

## Limitations

- **Elastic IPs are not supported** with autoscaling (instances get dynamic IPs)
- **EBS pool size is fixed** at `max_size` — you can't scale-out beyond that without provisioning more volumes
- **EBS volumes are AZ-specific** — uneven AZ load can leave volumes stranded
- **`instance_count` is ignored** when `autoscaling.enable === true`

## Deployment Strategies

Three options when shipping a new release to autoscaled instances:

### Strategy 1 — Ansible deploy (fast)

```bash
mix deploy_ex.upload
mix ansible.deploy
```

- All instances update simultaneously
- Brief unavailability per instance during restart
- Best for: quick fixes, low-traffic windows
- Pro: fast, no instance replacement
- Con: not zero-downtime

### Strategy 2 — Instance refresh (zero-downtime)

```bash
mix deploy_ex.upload
mix deploy_ex.autoscale.refresh <app> --wait
```

- AWS replaces instances gradually, maintaining a healthy floor
- New instances pull from S3 via user-data
- Auto-rollback on health check failure
- Best for: production deploys
- Pro: zero downtime, gradual rollout
- Con: slower; uses extra capacity during refresh

Use `--strategy ReplaceRootVolume` for in-place root volume swaps when you don't want full instance churn.

### Strategy 3 — Manual scale cycle (test environments)

```bash
mix deploy_ex.upload
mix deploy_ex.autoscale.scale <app> 0
sleep 30
mix deploy_ex.autoscale.scale <app> 3
```

- Forces every instance to be brand new
- Capacity drops to zero during the cycle
- Best for: dev/staging where downtime is fine and you want a guaranteed-clean fleet

## See also

- [How to manage autoscaling](../how-to/autoscaling.md) — commands
- [Terraform variables](../reference/terraform_variables.md) — full schema
- [Troubleshooting → Autoscaling](../how-to/troubleshooting.md#autoscaling)
- [Clustering](../how-to/clustering.md) — libcluster + EC2Tag
