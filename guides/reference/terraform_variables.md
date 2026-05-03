# Managing Terraform Variables

`deploys/terraform/variables.tf` is the source of truth for everything per-app: instance type, count, load balancer, EBS, autoscaling, scheduling. Editing it and running `mix terraform.apply` is **the** way to change infrastructure — not the AWS console, not direct CLI calls. This page covers the full schema and the day-to-day workflow.

## File Layout

After `mix deploy_ex.full_setup` (or `mix terraform.build`), your repo has:

```
deploys/
  terraform/
    variables.tf       <-- you edit this — per-app config
    ec2.tf             <-- generated; references variables.tf
    network.tf         <-- VPC, subnets, security groups
    iam.tf             <-- instance profiles, policies
    bucket.tf          <-- release / log buckets
    database.tf        <-- RDS (if --no-database wasn't passed)
    providers.tf       <-- AWS provider + S3 backend
    outputs.tf         <-- terraform.output reads these
    key-pair-main.tf   <-- generated PEM key pair
    modules/
      aws-instance/    <-- the EC2 + ALB + ASG module
      aws-database/    <-- RDS module
      aws-s3-upload-bucket/
```

You own everything in `deploys/`. Commit it. `mix terraform.build` only **adds** new app entries to `variables.tf` — it never overwrites your edits.

## The Workflow

The cycle for any infrastructure change:

```
1. Edit deploys/terraform/variables.tf
2. mix terraform.plan                    # preview the diff
3. Read it carefully
4. mix terraform.apply                   # apply (use -y to skip confirmation)
5. mix ansible.build                     # if instance count or apps changed
6. mix ansible.setup --only <app>        # if new instances were added
7. mix ansible.deploy --only <app>       # ship the release to the new instances
```

For changes that don't affect Ansible inventory (e.g. instance type, EBS size), steps 5–7 are unnecessary.

## App Variable Schema

The most important variable is `<app_name>_project` — one map per release in your `mix.exs`. Each map defines per-app infrastructure.

```hcl
my_app_project = {
  my_app = {
    name              = "My App"            # display name; do not change after creation
    instance_count    = 2                   # ignored when autoscaling.enable = true
    instance_type     = "t3.nano"
    instance_ami      = "ami-..."           # optional; defaults to latest base AMI
    private_ip        = "10.0.1.20"         # optional; static private IP (single-instance only)
    enable_eip        = false               # Elastic IP for static URL
    disable_ipv6      = false
    disable_public_ip = false               # internal-only services
    app_port          = 4000                # systemd PORT env (default 4000)
    use_latest_ami    = false               # always boot from latest matching AMI

    preserve_eip_for_single_instance_asg = false

    load_balancer = { ... }                 # see below
    autoscaling   = { ... }                 # see below
    ebs           = { ... }                 # see below
    tags          = { Owner = "team-backend" }
  }
}
```

### Top-level fields

| Field | Default | Notes |
|-------|---------|-------|
| `name` | required | Display name; affects tags. **Do not change after first apply** — instance Name tag derives from this |
| `instance_count` | `1` | Ignored when `autoscaling.enable = true` |
| `instance_type` | `t3.nano` | Any valid EC2 instance type |
| `instance_ami` | latest base AMI | Override the base Debian AMI |
| `private_ip` | DHCP | Static private IP — single instance only |
| `enable_eip` | `false` | Allocate an Elastic IP — incompatible with autoscaling unless `preserve_eip_for_single_instance_asg = true` |
| `disable_ipv6` | `false` | IPv6 is enabled by default |
| `disable_public_ip` | `false` | Skip public IP — internal-only services |
| `app_port` | `4000` | Internal app listening port; used by LB target group |
| `use_latest_ami` | `false` | Re-resolve AMI on every apply (forces instance refresh) |
| `tags` | `{}` | Extra tags merged onto the EC2 resource |

### `load_balancer`

```hcl
load_balancer = {
  enable        = true
  enable_https  = false
  port          = 80
  instance_port = 4000

  health_check = {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200-299,301"
    https_matcher       = "200-299"
    unhealthy_threshold = 2
    healthy_threshold   = 2
    timeout             = 5
    interval            = 20
  }
}
```

| Field | Default | Notes |
|-------|---------|-------|
| `enable` | `false` | Required when `instance_count > 1` or autoscaling |
| `enable_https` | `false` | Adds a 443 listener; needs an ACM cert (set up separately) |
| `port` | `80` | LB listener port (the URL clients hit) |
| `instance_port` | `4000` | Forwarded port on the instance |
| `health_check.path` | `/` | Endpoint hit by the LB |
| `health_check.matcher` | `200-299,301` | HTTP status codes considered healthy |
| `health_check.unhealthy_threshold` | `2` | Failed checks before unhealthy |
| `health_check.healthy_threshold` | `2` | Successful checks before healthy |
| `health_check.timeout` | `5` | Seconds per check |
| `health_check.interval` | `20` | Seconds between checks |

### `autoscaling`

```hcl
autoscaling = {
  enable                  = true
  min_size                = 1
  max_size                = 5
  desired_capacity        = 2
  cpu_target_percent      = 60
  scale_in_cooldown       = 300
  scale_out_cooldown      = 300
  ignore_capacity_changes = false      # see below
}
```

| Field | Default | Notes |
|-------|---------|-------|
| `enable` | `false` | Turn autoscaling on |
| `min_size` | required | Hard floor — ASG never goes below this |
| `max_size` | required | Hard ceiling — also defines EBS volume pool size |
| `desired_capacity` | `min_size` | Initial instance count Terraform applies |
| `cpu_target_percent` | `60` | Target average CPU; AWS scales to maintain it |
| `scale_in_cooldown` | `300` | Seconds after a scale-in before another can fire |
| `scale_out_cooldown` | `300` | Seconds after a scale-out before another can fire |
| `ignore_capacity_changes` | `false` | When `true`, Terraform stops managing `desired_capacity` after first apply (lets AWS or `mix deploy_ex.autoscale.scale` own runtime capacity). When `false`, every `terraform.apply` resets capacity to whatever's in this file |
| `switch_disable_delay_minutes` | `0` | For multi-template scheduled scaling (see below) |

#### `ignore_capacity_changes` — pick one

This flag determines whether your terraform variables file or the AWS autoscaler is the source of truth for capacity:

| Value | Behaviour | Use when |
|-------|-----------|----------|
| `false` (default) | Terraform manages `desired_capacity`. CPU-based scaling still works between applies, but `terraform.apply` resets capacity to the configured value. | You want capacity declared in code; manual scale operations are temporary. |
| `true` | Terraform sets capacity once, then ignores drift. CPU autoscaling and `mix deploy_ex.autoscale.scale` own runtime capacity forever. | You expect frequent runtime overrides, or capacity changes too often to track in version control. |

The original deploy_ex shipped with `ignore_capacity_changes` effectively `true` (ignored drift). Newer setups default to `false` so `variables.tf` stays the source of truth. **Pick one and stick with it** — flipping mid-flight will fight ongoing scale events.

#### `templates` (multi-template + scheduled scaling)

For complex schedules — e.g. high capacity during business hours, low overnight — use `templates`:

```hcl
autoscaling = {
  enable             = true
  min_size           = 1
  max_size           = 10
  desired_capacity   = 2
  cpu_target_percent = 60

  switch_disable_delay_minutes = 5

  templates = {
    business_hours = {
      instance_type    = "t3.large"
      min_size         = 5
      max_size         = 20
      desired_capacity = 10

      scheduling = [
        {
          name       = "weekday-up"
          recurrence = "0 8 * * MON-FRI"     # cron: 8am Mon-Fri
          time_zone  = "America/Los_Angeles"
          changes    = { min_size = 5, max_size = 20, desired_capacity = 10 }
        }
      ]
    }

    overnight = {
      instance_type    = "t3.small"
      min_size         = 1
      max_size         = 3
      desired_capacity = 1

      scheduling = [
        {
          name       = "weekday-down"
          recurrence = "0 19 * * MON-FRI"    # cron: 7pm Mon-Fri
          time_zone  = "America/Los_Angeles"
          changes    = { min_size = 1, max_size = 3, desired_capacity = 1 }
        }
      ]
    }
  }
}
```

When `templates` is set:
- Each template has its own Launch Template (different `instance_type` / `instance_ami`)
- `scheduling` entries become AWS scheduled actions that flip min/max/desired
- `switch_disable_delay_minutes` adds a per-schedule disable window so swaps don't conflict
- `ignore_capacity_changes` per template controls whether scheduled-scaling-driven changes get reverted on `terraform.apply`

Without `templates`, you get a single Launch Template using the top-level `instance_type` — most apps need only this.

### `ebs`

```hcl
ebs = {
  enable_secondary       = true
  primary_size           = 16
  secondary_size         = 16
  secondary_snapshot_id  = "snap-..."
}
```

| Field | Default | Notes |
|-------|---------|-------|
| `enable_secondary` | `false` | Add a secondary EBS volume mounted at `/data` |
| `primary_size` | `16` | Root volume size (GB) |
| `secondary_size` | `16` | Secondary volume size (GB) |
| `secondary_snapshot_id` | `null` | Restore the secondary volume from this snapshot |

When autoscaling is enabled, deploy_ex provisions a pool of secondary volumes equal to `max_size` (one per potential instance) so any instance can attach one in its AZ.

## Common Workflows

### Add a new app to existing infrastructure

After adding a new release to `mix.exs`:

```bash
mix terraform.build                          # adds the new <app>_project entry to variables.tf
# Edit variables.tf if you want non-default config
mix terraform.plan                           # preview
mix terraform.apply -y
mix ansible.build
mix ansible.setup --only my_new_app
mix ansible.deploy --only my_new_app
```

`terraform.build` is **additive** — it merges new app entries into `variables.tf` without disturbing your existing edits.

### Bump an instance type

```hcl
my_app_project = {
  my_app = {
    instance_type = "t3.medium"     # was "t3.small"
    ...
  }
}
```

```bash
mix terraform.plan                           # confirms the AMI swap
mix terraform.apply
```

For a non-autoscaled app this terminates and recreates the instance. For autoscaled apps, see [Autoscaling explanation](../explanation/autoscaling.md) — a rolling instance refresh is usually preferable to an in-place type change.

### Add a load balancer to a single-instance app

```hcl
my_app = {
  instance_count = 2                # bump capacity first
  load_balancer = {
    enable        = true
    port          = 80
    instance_port = 4000
    health_check  = { path = "/health" }
  }
}
```

```bash
mix terraform.plan                           # confirms LB + target group + listeners
mix terraform.apply
mix ansible.build                            # so Ansible knows about the new instance
mix ansible.setup --only my_app
mix ansible.deploy --only my_app
```

### Enable autoscaling on a static-count app

```hcl
my_app = {
  # instance_count is now ignored
  instance_type = "t3.small"
  autoscaling = {
    enable             = true
    min_size           = 2
    max_size           = 10
    desired_capacity   = 3
    cpu_target_percent = 60
  }
  load_balancer = { enable = true, port = 80, instance_port = 4000 }
}
```

```bash
mix terraform.plan                           # creates ASG + Launch Template + NLB target group
mix terraform.apply
```

### Targeting a single app on apply

If you only changed one app and want to skip planning everything else:

```bash
mix terraform.apply --target my_app
mix terraform.plan --target my_app --target my_other_app
```

`--target` automatically expands to `module.ec2_instance["<app>"]`, so the value is the app key (not the full module path).

### Pin per-command defaults

If you always pass `--var-file=production.tfvars`, hard-code it:

```elixir
# config/config.exs
config :deploy_ex, :terraform_default_args, %{
  apply: ["--var-file=production.tfvars"],
  plan: ["--var-file=production.tfvars"],
  destroy: ["--var-file=production.tfvars"]
}
```

CLI args take precedence over config defaults. Applies to: `:apply`, `:plan`, `:destroy`, `:refresh`, `:replace`, `:init`, `:output`.

### Remove an app

1. Delete the app entry from `variables.tf` (and any associated `mix.exs` release)
2. `mix terraform.plan` — confirm only the targeted resources are destroyed
3. `mix terraform.apply`
4. `mix deploy_ex.full_drop` is **not** needed — that wipes everything

## Variables Beyond the Schema

For changes that go beyond the per-app schema (e.g. add a new IAM policy, customize the VPC, add an SQS queue), edit the relevant `.tf` file directly:

- `iam.tf` — IAM roles, policies, instance profiles
- `network.tf` — VPC, subnets, security groups, NACLs
- `bucket.tf` — extra S3 buckets
- `database.tf` — RDS instances, parameter groups
- `modules/aws-instance/` — change instance/ASG behaviour for every app

Custom resources persist through `mix terraform.build` runs — that command only touches the `<app>_project` variable defaults.

## See also

- [How to manage autoscaling](../how-to/autoscaling.md) — runtime commands
- [Autoscaling internals](../explanation/autoscaling.md) — lifecycle + deployment strategies
- [Configuration Reference](configuration.md) — `:deploy_ex` config keys
- [Architecture — template pipeline](../explanation/architecture.md#template-pipeline)
- [Troubleshooting → Database / Autoscaling](../how-to/troubleshooting.md)
