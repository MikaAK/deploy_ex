# Agents

## Purpose
Top-level library source for DeployEx. Contains the core modules and Mix task definitions.

## Structure
- `deploy_ex/` — Core AWS infrastructure, release, and utility modules.
- `deploy_ex.ex` — Root module definition.
- `mix/` — Mix task helpers and CLI task implementations.

## Working agreements
- All public library code lives under `deploy_ex/`; Mix tasks live under `mix/tasks/`.
- Shared helpers used by multiple tasks belong in `mix/deploy_ex_helpers.ex`.
- Follow existing module naming: `DeployEx.<Domain>` for core, `Mix.Tasks.<Namespace>` for tasks.
