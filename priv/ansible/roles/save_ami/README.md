# Save AMI Role

This Ansible role automatically creates an Amazon Machine Image (AMI) from a configured EC2 instance. It's designed to be run as the final step in instance provisioning to enable fast boot for all instances (both autoscaling and regular).

## Purpose

All instances (autoscaling and regular) can boot from pre-configured AMIs instead of running full setup every time. This reduces boot time from **5-10 minutes to 60-90 seconds**.

**Automatic Fallback**: The system automatically uses base Debian AMI on first deployment, then switches to custom AMI after it's created - no manual intervention needed.

## How It Works

1. **Ansible Roles Download**: Cloud-init downloads ansible-roles.tar.gz from S3
2. **Initial Instance Setup**: Cloud-init runs Ansible playbook with all roles including `save_ami`
3. **AMI Creation**: Role creates AMI with app-specific configuration
4. **SSM Storage**: AMI ID stored in SSM Parameter Store at `/deploy_ex/{environment}/{app_name}/latest_ami`
5. **Future Instances**: Use the custom AMI and only run `deploy_node` to fetch latest release

**No Lambda**: Everything runs directly via cloud-init on the instance.

## Workflow

```
┌─────────────────────────────────────────────────────────────┐
│ First Instance (Creates AMI)                                │
├─────────────────────────────────────────────────────────────┤
│ 1. Terraform checks SSM for custom AMI → Not found          │
│ 2. Automatically falls back to base Debian AMI              │
│ 3. Cloud-init downloads ansible-roles.tar.gz from S3        │
│ 4. Cloud-init runs all roles:                               │
│    - beam_linux_tuning                                      │
│    - pip3, awscli, ipv6                                     │
│    - prometheus_exporter                                    │
│    - grafana_loki_promtail                                  │
│    - log_cleanup                                            │
│    - deploy_node (fetch & start app)                        │
│    - save_ami ← Creates custom AMI                          │
│ 5. AMI ID saved to SSM Parameter Store                      │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ All Future Instances (Fast Boot - Auto & Regular)          │
├─────────────────────────────────────────────────────────────┤
│ 1. Terraform checks SSM → Custom AMI found                  │
│ 2. Custom AMI boots (already configured)                    │
│ 3. User data script runs deploy_node role only              │
│ 4. Fetches latest app release from S3                       │
│ 5. Starts service → Ready in ~60-90 seconds                 │
└─────────────────────────────────────────────────────────────┘
```

## Features

### AMI Management
- **Auto-naming**: `{app_name}-{environment}-{timestamp}`
- **Tagging**: Includes App, Environment, CreatedAt, ManagedBy, Type tags
- **No-reboot**: Creates AMI without stopping instance
- **Cleanup**: Automatically removes old AMIs (keeps last 3)

### SSM Integration
- Stores latest AMI ID in Parameter Store
- Path: `/deploy_ex/{environment}/{app_name}/latest_ami`
- Terraform automatically fetches latest AMI for autoscaling

### Non-blocking
- AMI creation runs async
- Instance doesn't wait for AMI to be ready
- Typically takes 5-10 minutes for AMI to be available

## Variables

```yaml
app_name: ""        # Application name (required)
environment: ""     # Environment (dev/staging/prod, required)
```

## IAM Permissions Required

The EC2 instance role needs:
```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:CreateImage",
    "ec2:CreateTags",
    "ec2:DescribeImages",
    "ec2:DeregisterImage",
    "ssm:PutParameter"
  ],
  "Resource": "*"
}
```

These are automatically added by the terraform module when `enable_autoscaling = true`.

## Cost Analysis

### Storage Costs
- **EBS Snapshots**: $0.05 per GB-month
- Example: 20 GB instance = **~$1/month**
- Keeps last 3 AMIs per app/environment

### Savings
- **Lambda execution**: Reduced from 300s to ~10s per scale event
- **Network**: No repeated package downloads
- **Time to healthy**: 5-8 minutes faster

**ROI**: AMIs pay for themselves after 1-2 scale events.

## Usage

### In Terraform Config

```hcl
autoscaling = {
  enable = true
  min_size = 1
  max_size = 5
  use_custom_ami = true  # Enable custom AMI (default: true)
}
```

### Disable Custom AMI

To use base Debian AMI for autoscaling (slower but no AMI dependency):

```hcl
autoscaling = {
  enable = true
  use_custom_ami = false  # Will run full setup on each scale
}
```

## Troubleshooting

### First Instance Using Base AMI
This is expected behavior:
1. First deployment has no custom AMI yet
2. System automatically falls back to base Debian AMI
3. After setup completes, custom AMI is created
4. All future instances will use the custom AMI

No action needed - this is the intended workflow.

### Old AMIs Not Cleaning Up
- Cleanup runs async and may fail silently
- Check instance CloudWatch logs for errors
- Manually deregister old AMIs via AWS Console if needed

### AMI Creation Failed
- Check IAM permissions on instance role
- Verify SSM Parameter Store write permissions
- Review instance logs at `/var/log/ansible.log`

## Files

- `tasks/main.yaml` - Main role tasks
- `defaults/main.yaml` - Default variables
- `README.md` - This file

## Related Files

- `/priv/terraform/ansible_roles_bucket.tf.eex` - S3 bucket for ansible roles distribution
- `/priv/terraform/modules/aws-instance/cloud_init_full_setup.sh.tftpl` - Full setup script that runs this role
- `/priv/terraform/modules/aws-instance/cloud_init_autoscale_deploy.sh.tftpl` - Fast boot script for future instances
- `/priv/terraform/modules/aws-instance/main.tf` - Terraform module that uses the AMIs
