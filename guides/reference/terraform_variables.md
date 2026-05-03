# Terraform Variables Reference

The main variables file is `deploys/terraform/variables.tf`. The most important entry is `<app_name>_project` — one map per release in your `mix.exs`. Each map defines per-app infrastructure.

## App Variable Schema

```hcl
my_app_project = {
  my_app = {
    name              = "My App"            # display name; do not change after creation
    instance_count    = 2                   # ignored when autoscaling.enable = true
    instance_type     = "t3.nano"
    instance_ami      = "ami-..."           # optional; defaults to latest base AMI
    private_ip        = "10.0.1.20"         # optional; static private IP
    enable_eip        = false               # Elastic IP for static URL
    disable_ipv6      = false
    disable_public_ip = false

    load_balancer = { ... }                 # see below
    autoscaling   = { ... }                 # see below
    ebs           = { ... }                 # see below
    tags          = ["Owner=team-backend"]
  }
}
```

### Top-level fields

| Field | Default | Notes |
|-------|---------|-------|
| `name` | required | Display name; affects tags. Don't change after first apply — the instance Name tag is derived from this |
| `instance_count` | 1 | Ignored when autoscaling is enabled |
| `instance_type` | `t3.nano` | Any valid EC2 instance type |
| `instance_ami` | latest base AMI | Override base Debian AMI |
| `private_ip` | (DHCP) | Static private IP — single instance only |
| `enable_eip` | `false` | Allocate an Elastic IP — incompatible with autoscaling |
| `disable_ipv6` | `false` | IPv6 is enabled by default |
| `disable_public_ip` | `false` | Skip public IP — internal-only services |
| `tags` | `[]` | Extra `Key=Value` tags appended to the EC2 resource |

### `load_balancer`

```hcl
load_balancer = {
  enable        = true
  enable_https  = false
  port          = 80                # ALB listener port
  instance_port = 4000              # forwarded to your app

  health_check = {
    path                = "/health"
    protocol            = "HTTP"    # or "HTTPS"
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
| `enable_https` | `false` | Enables a 443 listener |
| `port` | `80` | LB listener port (the URL clients hit) |
| `instance_port` | `4000` | Forwarded port on the instance (your app port) |
| `health_check.path` | `/` | Endpoint hit by the LB |
| `health_check.matcher` | `200-299,301` | HTTP status codes considered healthy |
| `health_check.unhealthy_threshold` | `2` | Failed checks before unhealthy |
| `health_check.healthy_threshold` | `2` | Successful checks before healthy |
| `health_check.timeout` | `5` | Seconds per check |
| `health_check.interval` | `20` | Seconds between checks |

### `autoscaling`

```hcl
autoscaling = {
  enable             = true
  min_size           = 1
  max_size           = 5
  desired_capacity   = 2
  cpu_target_percent = 60
  scale_in_cooldown  = 300
  scale_out_cooldown = 300
}
```

See [Autoscaling explanation](../explanation/autoscaling.md) for the full lifecycle.

### `ebs`

```hcl
ebs = {
  enable_secondary       = true
  primary_size           = 16            # GB; root volume
  secondary_size         = 16            # GB; mounted at /data
  secondary_snapshot_id  = "snap-..."    # restore from snapshot
}
```

| Field | Default | Notes |
|-------|---------|-------|
| `enable_secondary` | `false` | Add a secondary EBS volume mounted at `/data` |
| `primary_size` | `16` | GB; root volume size |
| `secondary_size` | `16` | GB; size of the secondary volume |
| `secondary_snapshot_id` | `null` | Restore the secondary volume from this snapshot |

When autoscaling is enabled, deploy_ex provisions a pool of secondary volumes equal to `max_size` (one per potential instance) so any instance can attach one in its AZ.

## Targeting

Use `--target` to scope `terraform.apply` / `terraform.plan` to a single app:

```bash
mix terraform.apply --target cfx_web
mix terraform.apply --target cfx_web --target cfx_api
mix terraform.plan --target cfx_web
```

The `--target` value expands to `module.ec2_instance["<app>"]` automatically.

## Default Command Arguments

Pin per-command defaults in your config so you don't repeat them every run:

```elixir
config :deploy_ex, :terraform_default_args, %{
  apply: ["--var-file=production.tfvars"],
  plan: ["--var-file=production.tfvars"],
  destroy: ["--var-file=production.tfvars"]
}
```

CLI args take precedence over config defaults. Applies to: `:apply`, `:plan`, `:destroy`, `:refresh`, `:replace`, `:init`, `:output`.

## See also

- [Configuration Reference](configuration.md) — `:deploy_ex` config keys
- [Architecture — template pipeline](../explanation/architecture.md#template-pipeline)
- [Autoscaling explanation](../explanation/autoscaling.md)
