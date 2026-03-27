# How to Dump and Restore Databases

Database operations use SSH tunnels through a jump server to access RDS.

## Dump

```bash
# Custom format (recommended — supports parallel restore)
mix terraform.dump_database --format custom --output backup.pgdump

# SQL text format
mix terraform.dump_database --format text --output backup.sql

# Schema only
mix terraform.dump_database --schema-only --output schema.sql
```

## Restore

```bash
# Restore to RDS with parallel jobs
mix terraform.restore_database backup.pgdump --jobs 4

# Restore locally
mix terraform.restore_database backup.pgdump --local

# Clean restore (drop objects first)
mix terraform.restore_database backup.pgdump --clean
```

Auto-detects format: `.pgdump` uses `pg_restore`, `.sql` uses `psql`.

## Show Database Password

```bash
mix terraform.show_password
```

See also: [Mix Tasks Reference](../reference/mix_tasks.md)
