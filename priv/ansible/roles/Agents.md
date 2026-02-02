# Agents

## Purpose
Role definitions for instance setup, monitoring, and AMI management.

## Working agreements
- Keep tasks idempotent and safe to re-run.
- Use variables from group_vars and role defaults; avoid hardcoding.
- Ensure role outputs and tags align with DeployEx conventions.
