# Agents

## Purpose
DeployEx is an Elixir library that generates and manages AWS infrastructure with Terraform and Ansible, plus Mix tasks for deployment workflows.

## Working agreements
- Use DeployEx.Config for config and environment values; avoid runtime Mix.env.
- Use ErrorMessage and return {:ok, _} / {:error, ErrorMessage} for failures.
- Run shell commands through DeployEx.Utils for consistent output and error handling.
- ExAws requests must include region and follow tagging conventions (Group, Environment, ManagedBy).
- Update README when CLI flags, config, or user-facing behavior changes.
- Use `DeployEx.Config.aws_names_include_env?()` when building AWS resource name prefixes that may or may not include the environment (e.g., security groups, buckets).

## Key locations
- lib/deploy_ex: core AWS and release logic.
- lib/mix/tasks: Mix CLI tasks.
- priv/ansible and priv/terraform: templates and modules.
- test: ExUnit tests and fixtures.
