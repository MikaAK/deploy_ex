# Agents

## Purpose
Core modules for AWS infrastructure, releases, and runtime utilities.

## Working agreements
- Return {:ok, _} / {:error, ErrorMessage} and avoid raising in library code.
- Pass region to ExAws requests and keep tag conventions consistent.
- Use DeployEx.Utils for shell commands and IO streaming.
- Keep side effects out of init callbacks; use handle_continue when needed.
- Update Mix tasks and templates when adding new infrastructure flows.

## Key modules
- Aws* modules: EC2, S3, RDS, load balancer, autoscaling.
- Terraform and Ansible wrappers.
- QaNode and ReleaseUploader.
