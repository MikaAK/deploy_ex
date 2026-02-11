---
description: AWS infrastructure and resource conventions for DeployEx
---

# AWS Rules

## ExAws requests
- Always pass `:region` to ExAws operation calls.
- Tag all AWS resources with `Group`, `Environment`, and `ManagedBy`.

## Naming
- Use `DeployEx.Config.aws_names_include_env?()` when building resource name prefixes that may or may not include the environment (e.g., security groups, buckets).

## Shell commands
- Run shell commands through `DeployEx.Utils` for consistent output, logging, and error handling.
- Never shell out directly from Mix tasks or library modules.

## Terraform
- Keep Terraform resource tags consistent with `resource_group`, `environment`, and `ManagedBy`.
- Update `variables.tf` and `outputs.tf` when module interfaces change.
- Ensure EEx templates in `priv/terraform/` stay compatible with `DeployEx.Terraform` module usage.

## Ansible
- Keep Ansible tasks idempotent and safe to re-run.
- Use variables from `group_vars` and role defaults; avoid hardcoding values.
- AWS CLI calls in playbooks must include region and required tags.
