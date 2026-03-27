# How to Deploy Releases

## Build, Upload, Deploy

```bash
mix deploy_ex.release [--only app1] [--force]   # build changed apps
mix deploy_ex.upload [--parallel]                 # upload to S3
mix ansible.deploy [--only app1]                  # deploy to instances
```

Change detection compares git SHAs, mix.lock diffs, and dependency trees. Use `--force` to rebuild all.

## Deploy a Specific SHA

```bash
mix ansible.deploy --target-sha abc1234
```

## Rollback

```bash
mix ansible.rollback my_app              # rollback to previous
mix ansible.rollback my_app --select     # pick from history
```

## GitHub Actions CI/CD

```bash
mix deploy_ex.install_github_action
```

Secrets prefixed with `__DEPLOY_EX__` are automatically injected as environment variables during deployment.

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Configuration](../reference/configuration.md)
