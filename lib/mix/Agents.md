# Agents

## Purpose
Mix helpers and shared CLI utilities for deploy_ex Mix tasks.

## Working agreements
- Keep helpers reusable by tasks.
- Use ErrorMessage for failures and {:ok, _} / {:error, ErrorMessage}.
- Use DeployEx.Config for defaults instead of Mix.env at runtime.
- Avoid shelling out directly; use DeployEx.Utils where possible.
