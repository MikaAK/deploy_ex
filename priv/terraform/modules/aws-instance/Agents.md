# Agents

## Purpose
Terraform module for provisioning AWS EC2 instances with cloud-init, EBS volumes, and optional autoscaling.

## Working agreements
- Keep variables well-documented with descriptions and sensible defaults.
- Tag all resources with `resource_group`, `environment`, and `ManagedBy`.
- Changes to variable interfaces must be reflected in the parent `ec2.tf.eex` template.
- The `cloud_init_data.yaml.tftpl` template must stay compatible with the Ansible setup flow.
