---
description: Conventions for EEx templates and priv assets in DeployEx
---

# Template and Priv Asset Rules

## EEx templates
- Keep EEx templates compatible with Mix task generators that render them.
- Templates use `DeployEx.Config` for runtime values like region, bucket names, and environment.
- Never hardcode secrets in templates; use placeholder values or machine-preloaded credentials.

## GitHub Actions
- CLI scripts in `priv/` are consumed by generated GitHub Action workflows.
- Update scripts and workflow templates together when changing CI behavior.

## Ansible templates
- Ansible playbook and role templates must stay in sync with Mix task generation.
- Variable names in `group_vars` templates must match expectations in role `defaults/` and `vars/`.

## Terraform templates
- Terraform EEx templates (`.tf.eex`) are rendered by `DeployEx.Terraform` and Mix tasks.
- Keep variable and output definitions consistent between modules and parent templates.
