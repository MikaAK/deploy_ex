# Agents

## Purpose
EEx template for Ansible group_vars (`all.yaml.eex`), providing shared variables across all hosts.

## Working agreements
- Variables are rendered at generation time by Mix tasks using `DeployEx.Config`.
- Never hardcode secrets; use placeholder values or preloaded machine credentials.
- Keep variable names consistent with role expectations in `../roles/`.
