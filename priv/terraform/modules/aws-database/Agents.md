# Agents

## Purpose
Terraform module for provisioning AWS RDS database instances with storage autoscaling and backup configuration.

## Working agreements
- Keep variables well-documented with descriptions and sensible defaults.
- Tag all resources with `resource_group`, `environment`, and `ManagedBy`.
- Changes to variable interfaces must be reflected in the parent `database.tf.eex` template.
- Database credentials are managed via Terraform; never expose them in outputs without marking sensitive.
