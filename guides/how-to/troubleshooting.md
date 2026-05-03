# Troubleshooting

Common problems and their fixes. Match the symptom, follow the steps. If nothing matches, file an issue with `mix deploy_ex.instance.status <app>` output.

## Setup & Connectivity

<details>
<summary><strong>Ansible setup is hanging forever</strong></summary>

With Debian 13 the `/tmp` folder behaviour changed and small nodes sometimes run out of space.

```bash
eval "$(mix deploy_ex.ssh -s --root <app>)"
df -h
# If /tmp is at 100%:
rm -rf /tmp/*
```
</details>

<details>
<summary><strong>Ansible says "no hosts matched" or <code>mix deploy_ex.ssh</code> can't connect</strong></summary>

Public IPs change when instances are stopped/started without an EIP. Refresh the inventory:

```bash
mix terraform.refresh
```
</details>

<details>
<summary><strong>SSH "Too Many Authentication Failures"</strong></summary>

Add to `~/.ssh/config`:

```
Host *
  IdentitiesOnly yes
```

[Why this works](https://www.tecmint.com/fix-ssh-too-many-authentication-failures-error/) — your SSH agent is offering too many keys.
</details>

<details>
<summary><strong>SSH timing out</strong></summary>

By default, SSH ingress is locked down. Whitelist your current IP first:

```bash
mix deploy_ex.ssh.authorize
```

Remove it when you're done:

```bash
mix deploy_ex.ssh.authorize --remove
```
</details>

<details>
<summary><strong><code>mix deploy_ex.full_setup</code> ends with "Operation timed out"</strong></summary>

Sometimes nodes take a few minutes to fully initialise. Re-run `mix ansible.ping` after a couple of minutes; setup will succeed.
</details>

## Releases & Deploys

<details>
<summary><strong>How do I redeploy a node?</strong></summary>

```bash
mix ansible.deploy --only <app>
```

This finds every instance matching the app name and redeploys with the latest release in S3.
</details>

<details>
<summary><strong>How do I replace a broken node?</strong></summary>

```bash
mix terraform.replace -n <app>                  # replace one instance
mix terraform.replace -n <app> --node 2         # specific node by index
mix ansible.setup --only <app>
mix ansible.deploy --only <app>
```

Or in one shot: `mix deploy_ex.remake <app>`.
</details>

<details>
<summary><strong>How do I restart a service without redeploying?</strong></summary>

```bash
mix deploy_ex.restart_app <app>
# or, manually:
eval "$(mix deploy_ex.ssh -s --root <app>)"
systemctl restart <app>
```
</details>

<details>
<summary><strong>How do I uninstall deploy_ex?</strong></summary>

```bash
mix deploy_ex.full_drop      # add -y to skip confirmation
```

Removes all AWS resources and deletes `./deploys/`.
</details>

## Autoscaling

<details>
<summary><strong>Instances aren't joining the cluster</strong></summary>

Check libcluster discovery:
- `Group` and `InstanceGroup` tags must be set on instances
- libcluster config must use `Cluster.Strategy.EC2Tag`
- Security groups must allow inter-instance traffic (the default deploy_ex SG does)
- `mix deploy_ex.autoscale.status <app>` should show all instances `InService`
</details>

<details>
<summary><strong>User-data script failed</strong></summary>

```bash
mix deploy_ex.ssh <app> --index 0
sudo cat /var/log/user-data.log
sudo journalctl -u cloud-final
```

Common causes:
- IAM role missing S3 / EC2 permissions
- Release tarball not in S3
- SSH key missing for cross-instance release discovery
- Network egress blocked
</details>

<details>
<summary><strong>Terraform shows drift on <code>desired_capacity</code></strong></summary>

That drift is **expected**. The ASG has `lifecycle { ignore_changes = [desired_capacity] }` so AWS can scale dynamically without Terraform fighting it. Running `terraform.apply` won't change capacity — use `mix deploy_ex.autoscale.scale <app> <n>`.
</details>

<details>
<summary><strong>Scale-in isn't happening</strong></summary>

- `min_size` must be lower than current capacity
- CPU must actually drop below `cpu_target_percent`
- `scale_in_cooldown` (default 300s) blocks consecutive scale-ins
- No instance scale-in protection set
- Verify with CloudWatch CPU metrics
</details>

<details>
<summary><strong>New autoscaled instances run the wrong version</strong></summary>

User-data tries to read `/srv/current_release.txt` from an existing instance, then falls back to the latest S3 release. Causes of mismatch:
- SSH between instances broken (Launch Template missing the key)
- Security groups don't allow inter-instance SSH
- `/srv/current_release.txt` not present on running instances (Ansible never finished)
- No releases in S3
- Check `/var/log/user-data.log` for the discovery trace
</details>

<details>
<summary><strong>EBS volumes not attaching to autoscaled instances</strong></summary>

- Volume pool size must equal `max_size` (one volume per potential instance)
- Volumes are AZ-specific — they only attach to instances in the same AZ
- IAM role needs `ec2:AttachVolume` and `ec2:DescribeVolumes`
- `InstanceGroup` tag must match between volume and instance
- Look at `/var/log/user-data.log` on the instance
</details>

## Database

<details>
<summary><strong>RDS major version upgrade (e.g. Postgres 16 → 18)</strong></summary>

deploy_ex's RDS module sets `allow_major_version_upgrade = true` and uses `create_before_destroy` on parameter groups, so most upgrades go through with one `terraform.apply`. The exception: when both the engine version **and** the parameter group family change in the same apply, AWS rejects it — a `postgres18` parameter group can't be applied to an instance still running `postgres16`.

**Two-step apply:**

1. **Engine upgrade only.** In `deploys/terraform/modules/aws-database/main.tf`, comment out the custom parameter group reference and add `apply_immediately`:

   ```hcl
   # parameter_group_name       = aws_db_parameter_group.rds_database_parameter_group.name
   allow_major_version_upgrade = true
   apply_immediately           = true
   ```

   Run `mix terraform.apply`. AWS upgrades the engine and assigns the default parameter group. Allow 10–20+ minutes.

2. **Re-attach the custom parameter group.** Once the upgrade finishes, uncomment `parameter_group_name` and remove `apply_immediately`:

   ```hcl
   parameter_group_name        = aws_db_parameter_group.rds_database_parameter_group.name
   allow_major_version_upgrade = true
   ```

   Run `mix terraform.apply` again. Terraform creates the version-suffixed parameter group (e.g. `my-app-db-dev-params-18`), attaches it, and deletes the old one.
</details>

## Monitoring

<details>
<summary><strong>Monitoring is failing — what do I check?</strong></summary>

There are several services running across different node types:

| Service | Where it runs | What it does |
|---------|---------------|--------------|
| `alloy` | every app node | tails systemd journal, ships to Loki |
| `prometheus_exporter` | every app node | scrapes app + node metrics |
| `prometheus-server` | `prometheus` node | metrics database |
| `grafana-server` | `grafana_ui` node | UI / dashboards |
| `loki` | `loki_log_aggregator` node | log aggregator |

Restart whichever is failing, then tail logs:

```bash
mix deploy_ex.ssh <node> --log --all -n 50
```
</details>

## Tags & Operations

<details>
<summary><strong>Why are there so many tags on my EC2 nodes?</strong></summary>

deploy_ex tags every resource for cost allocation and operational filtering:

| Tag | Purpose |
|-----|---------|
| `Group` | Clustering — used by libcluster's `EC2Tag` strategy and for billing rollups across all backend services |
| `InstanceGroup` | Per-app billing and Ansible targeting (one value per service/app) |
| `MonitoringKey` | Identifies monitoring nodes for playbook discovery |
| `Vendor` | Source — `Self` for in-house apps, `Grafana`/`Sentry`/etc. for vendors |
| `Type` | Role — `Monitoring`, `Self Made`, etc. — separates infra cost from app cost |
| `Environment` | dev/staging/prod |
| `ManagedBy` | Always `DeployEx` — distinguishes managed resources from manual ones |
| `App` | App identifier on per-app AMIs |

Cloud billing UIs are bad at attributing cost; these tags make AWS Cost Explorer usable.
</details>

## Erlang Runtime

<details>
<summary><strong>How do I deploy with <code>include_erts: false</code> (Erlang installed on the node)?</strong></summary>

Use at least a `t3.small` — smaller nodes can run out of memory during `asdf install erlang`. If the install step bombs out, SSH onto the node and run it manually:

```bash
asdf install erlang <version-from-ansible>
```

Then in `deploys/ansible/setup/<app>.yaml` add the `elixir-runner` role, and in `deploys/ansible/playbook/<app>.yaml` set `extra_env`:

```yaml
- hosts: group_<app>
  vars:
    extra_env:
      - PATH=/root/.asdf/shims:/root/.asdf/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Then:

```bash
mix ansible.setup --only <app>
mix ansible.deploy --only <app>
```
</details>

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Connecting to Nodes](connecting_to_nodes.md) | [Managing Infrastructure](managing_infrastructure.md)
