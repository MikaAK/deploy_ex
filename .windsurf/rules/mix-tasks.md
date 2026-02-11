---
description: Conventions for DeployEx Mix tasks and CLI commands
---

# Mix Task Rules

## Argument parsing
- Parse arguments with `OptionParser` and keep flags aligned with README documentation.
- Update the README when adding or changing CLI flags, config, or user-facing behavior.

## Shared helpers
- Use `DeployExHelpers` for common IO and task utilities.
- Use `DeployEx.Config` for defaults instead of `Mix.env()` at runtime.
- Use `DeployEx.Utils` for shell command execution.

## Structure
- Keep long-running work in helper functions, not in the task's `run/1` body directly.
- Ensure tasks check umbrella requirements and provide clear `Mix.shell()` output.
- Follow the existing naming convention: `Mix.Tasks.DeployEx.<Domain>.<Action>`.

## Migrations and schemas
- Write migrations when creating new Ecto schemas.
- Add proper indexes to schemas.
