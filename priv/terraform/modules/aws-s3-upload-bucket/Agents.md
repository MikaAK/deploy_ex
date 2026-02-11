# Agents

## Purpose
Terraform module for provisioning S3 upload buckets with optional CloudFront CDN distribution.

## Working agreements
- Keep variables well-documented with descriptions and sensible defaults.
- Tag all resources with `resource_group`, `environment`, and `ManagedBy`.
- CDN configuration is opt-in via `enable_cdn`; ensure CDN variables are only required when enabled.
- CORS and signing key configuration must stay flexible for different deployment scenarios.
