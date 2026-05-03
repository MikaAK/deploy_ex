# How to Manage Infrastructure

## Regenerate Terraform / Ansible Files

After changing config or adding releases:

```bash
mix terraform.build    # regenerate .tf files
mix terraform.plan     # preview changes
mix terraform.apply    # provision (use `-y` to auto-approve)
mix ansible.build      # regenerate playbooks
```

`terraform.build` and `ansible.build` accept opt-out flags for monitoring services:

| Flag | Disables |
|------|----------|
| `--no-database` | RDS Postgres |
| `--no-redis` | Redis (and Redis Stack) |
| `--no-grafana` | Grafana UI |
| `--no-loki` | Grafana Loki + Alloy log shipping |
| `--no-prometheus` | Prometheus + node_exporter |
| `--no-sentry` | Sentry server |
| `--no-logging` | All log shipping (Loki + Alloy) |

## Replace EC2 Instances

```bash
mix terraform.replace -n my_app                   # replace by node count selector
mix terraform.replace -s my_app -y                # match string + auto-approve
mix terraform.replace --all                       # replace every managed instance
```

`-n` is integer (replace `n` instances of an app); `-s` is a string substring match.

## EBS Snapshots

```bash
mix terraform.create_ebs_snapshot --description "pre-deploy"
mix terraform.create_ebs_snapshot --include-root
mix terraform.delete_ebs_snapshot --all
mix terraform.delete_ebs_snapshot --max-age-days 30
mix terraform.delete_ebs_snapshot --snapshot-ids snap-aaa,snap-bbb
```

## Database Operations

```bash
mix terraform.dump_database --format custom --output backup.pgdump
mix terraform.dump_database --format text --schema-only
mix terraform.restore_database backup.pgdump --jobs 4
mix terraform.restore_database backup.pgdump --local --clean
```

Database access goes over an SSH tunnel through the jump server. Format auto-detection: `.pgdump` → `pg_restore`, `.sql` → `psql`. See [Database Operations](database_operations.md) for details.

```bash
mix terraform.show_password                       # show RDS password
mix terraform.generate_pem                        # extract SSH PEM from Terraform state
```

## Terraform State

```bash
mix terraform.refresh                             # sync state with AWS
mix terraform.output                              # show all outputs
mix terraform.output -s                           # JSON output (short mode)

mix terraform.create_state_bucket                 # one-time S3 + lock-table bootstrap
mix terraform.create_state_lock_table
mix terraform.drop_state_bucket
mix terraform.drop_state_lock_table
```

The state backend defaults to `:s3` with a DynamoDB lock table. Override via `:terraform_backend` config (`:s3` or `:local`).

## Upgrade Templates After Updating deploy_ex

deploy_ex ships templates inside the dependency. Two commands manage them:

```bash
mix deploy_ex.export_priv          # render & copy templates into ./deploys/ (writes manifest)
mix deploy_ex.upgrade_priv         # interactive per-hunk merge with upstream changes
mix deploy_ex.upgrade_priv --ai-review    # LLM proposes accept/reject per file; you confirm
mix deploy_ex.upgrade_priv --llm-merge    # LLM applies all changes autonomously (with backup)
```

How upgrade detects changes:

1. **Render** — runs the same EEx templates `terraform.build` and `ansible.build` use, into a temp dir.
2. **Plan** — `DeployEx.ChangePlanner` compares the rendered tree against `./deploys/`, classifying each file as `:identical`, `:update`, `:rename`, `:split`, `:merge_files`, `:new`, `:removed`, or `:user_only`. Renames/splits use Jaro distance + LLM disambiguation.
3. **Backup** — every file that will be modified is copied to a timestamped backup directory.
4. **Apply** — interactive (DiffViewer per hunk), AI-assisted (LLM proposes per file), or autonomous (LLM merges all).
5. **Manifest** — `.deploy_ex_manifest.exs` (sha256 per file + deploy_ex version) is rewritten so the next upgrade can detect user modifications vs. drift.

LLM modes need `:deploy_ex, :llm_provider` configured in `config/*.exs`.

## Tear Down

```bash
mix terraform.drop                                # destroy infrastructure (use `-y` to skip confirmation)
mix deploy_ex.full_drop                           # destroy infra + remove ./deploys/ + remove .github workflows + drop state bucket/lock table
```

`full_drop` is a destructive one-way operation that wipes Terraform state. Always confirm before running.

See also: [Mix Tasks Reference](../reference/mix_tasks.md) | [Configuration](../reference/configuration.md) | [Architecture](../explanation/architecture.md)
