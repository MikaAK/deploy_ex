# Agents

## Purpose
Release upload pipeline, state tracking, and update validation.

## Working agreements
- Keep S3 operations in AwsManager and handle responses with ErrorMessage.
- UpdateValidator should remain deterministic and concurrency-limited.
- Avoid side effects outside upload and git diff commands.
- Maintain release naming conventions and SHA parsing.
