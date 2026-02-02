# Agents

## Purpose
Ansible templates, playbooks, and inventory used to configure instances.

## Working agreements
- Keep templates in sync with Mix task generation.
- Prefer idempotent tasks and explicit become usage.
- AWS CLI calls must include region and required tags.
- Update README when new roles or variables are introduced.
