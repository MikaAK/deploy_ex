# Agents

## Purpose
Mix tasks for deployment workflows (ansible, terraform, QA nodes, releases, ssh).

## Working agreements
- Parse args with OptionParser and keep flags aligned with README.
- Use DeployExHelpers, DeployEx.Config, and DeployEx.Utils for IO and config.
- Ensure tasks check umbrella requirements and provide clear Mix.shell output.
- Keep long-running work in helper functions, not task initialization.
