# How to Manage Infrastructure

## Regenerate Terraform/Ansible Files

After changing config or adding releases:

```bash
mix terraform.build    # regenerate .tf files
mix terraform.plan     # preview changes
mix terraform.apply    # provision
mix ansible.build      # regenerate playbooks
```

## Upgrade Templates After Updating deploy_ex

```bash
mix deploy_ex.upgrade_priv
```

Uses SHA256 manifest tracking: unmodified files are silently updated, user-modified files get a backup + diff. Use `--llm-merge` for AI-assisted 3-way merges.

## Replace EC2 Instances

```bash
mix terraform.replace -n my_app [-y]     # specific app
mix terraform.replace -n my_app --all    # all instances
```

## EBS Snapshots

```bash
mix terraform.create_ebs_snapshot my_app [--description "pre-deploy"]
mix terraform.delete_ebs_snapshot [--all] [--max-age-days 30]
```

## Terraform State

```bash
mix terraform.refresh        # sync state with AWS
mix terraform.output [-s]    # show outputs (-s for JSON)
mix terraform.generate_pem   # extract PEM from state
```

## Tear Down

```bash
mix terraform.drop [-y]              # destroy all infrastructure
mix deploy_ex.full_drop              # remove all deploy_ex files
```

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Configuration](../reference/configuration.md)
