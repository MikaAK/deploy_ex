# clickhouse

> **STATUS: verified against a live host. One item is untestable without
> credentials this project does not hold.**
>
> Verified 2026-08-12 on throwaway OCI Ubuntu 24.04 hosts:
>
> | item | result |
> |---|---|
> | role runs green | PASSED — `failed=0`, service reached `active (running)` |
> | version pin | PASSED — `apt` history shows `clickhouse-server=24.8.14.39` installed fresh |
> | apt repo + GPG key URL | PASSED — the install above proves both resolve |
> | `clickhouse` system user/group | PASSED — `uid=999(clickhouse) gid=988(clickhouse)` |
> | cold tier OFF by default | PASSED — `config.d` held only `listen.xml` |
> | `SELECT 1` over TCP and HTTP | PASSED — `clickhouse-client` and `curl :8123` both return `1` |
> | default user from the configured CIDR | PASSED — connected over the host's own private IP (not loopback) with the CIDR set to the test VCN, so the CIDR entry is what was exercised |
> | cold tier ENABLED boots cleanly | PASSED — `NRestarts=0`, `active (running)`, `system.disks` shows `s3_cold ObjectStorage` and `system.storage_policies` the expected `tiered`/`hot`/`s3_cold` shape, booted with deliberately fake credentials — confirming `skip_access_check` behaves as its header claims |
> | second run is `changed=0` | NOT MET, and benign: the changes are `awscli` handlers plus this role's `Update apt cache`, which `cache_valid_time: 0` makes report changed every run by design (copied from `redis_server`). No clickhouse-role task drifts. |
> | cold tier against a REAL bucket | **UNTESTABLE HERE** — needs OCI Customer Secret Keys, an IAM write in the tenancy root |
>
> **On the loopback entries.** ClickHouse's `<networks>` check is literal and
> never implicitly permits 127.0.0.1, so an on-box healthcheck fails
> `AUTHENTICATION_FAILED` even with a confirmed-empty password — diagnosed from
> `preprocessed_configs/users.xml`, which showed `<password/>` correctly empty
> while the CIDR excluded loopback. Loopback is therefore listed unconditionally
> alongside the configured CIDR. Both paths are now confirmed working live.
>
> **Correction to an earlier version of this file.** It claimed the ClickHouse
> 24.8 deb's unit was broken on Ubuntu 24.04 systemd. That was WRONG. The service
> started cleanly on this exact host and package before any edit. The crash-loop
> appeared only after a `--` sequence landed inside an XML comment in
> `zz-allow-default-network.xml.j2`; XML 1.0 forbids that anywhere in a comment
> body, so Poco refused the file and the daemon exited before signalling
> readiness. systemd reports that as `Failed with result 'protocol'` — identical
> to a genuine `Type=notify` mismatch, which is why reading only `journalctl` led
> to the wrong conclusion. The ClickHouse error log named the file and line
> outright. Two lessons worth keeping: diagnose a daemon from ITS OWN log, not
> just systemd's view of it; and an elimination experiment that removes the wrong
> file proves nothing (`config.d/listen.xml` was removed while the actually
> broken `users.d/` fragment stayed in place).

Installs a pinned `clickhouse-server` (apt), configures it via `config.d`/`users.d`
drop-in fragments (never touching the package's stock `config.xml`), and manages
it as a systemd service. Written to match the app-side contract in
`opgg_umbrella/config/runtime.exs` (`CLICKHOUSE_URL_OVERRIDE`,
`CLICKHOUSE_CLUSTER_OVERRIDE`, `CLICKHOUSE_POOL_SIZE`,
`CLICKHOUSE_MIGRATE_URL_OVERRIDE`, `CLICKHOUSE_STORAGE_POLICY_OVERRIDE`) and
`opgg_umbrella/docker/clickhouse/storage-s3-tiered.xml` (the dev/doc reference
for the cold-storage tier this role deploys server-side).

## What it does

- Adds the official ClickHouse apt repo + GPG key, pins the install to
  `clickhouse_version.*` via `/etc/apt/preferences.d/clickhouse.pref` (major.minor
  pin, so patch releases can land but a version bump never silently upgrades
  the pinned line), and installs `clickhouse-server`/`clickhouse-client`.
- Renders `config.d/listen.xml` — listen host, HTTP/TCP/interserver ports,
  data dir, and a server-wide memory ceiling.
- Renders `users.d/zz-allow-default-network.xml` — opens the built-in
  `default` user (no password) to `clickhouse_allowed_network_cidr`, matching
  the app's `Ch` client (see `defaults/main.yaml`).
- Optionally renders `config.d/storage-s3-tiered.xml` — the S3 cold-storage
  tier's server-side `<storage_configuration>` — **off by default**.
- Enables and starts the `clickhouse-server` systemd unit the package ships.

Every task is idempotent (`copy`/`template`/`apt`/`systemd` with no `command`/
`shell` outside the one GPG-key step, which is itself guarded by a `stat`
check) — re-running the role with unchanged vars changes nothing.

## Cold-storage tier: operator runbook

`clickhouse_s3_cold_storage_enabled` defaults to `false`. Leave it there until
all of the following are true, in this order:

1. A real S3 (AWS) or OCI Object Storage (via its S3-compatibility endpoint)
   bucket exists for cold parts, with lifecycle/retention configured.
2. `clickhouse_s3_cold_bucket_endpoint` points at it, and (per the auth mode
   below) either the node's IAM role or
   `clickhouse_s3_cold_access_key_id`/`clickhouse_s3_cold_secret_access_key`
   grant `s3:GetObject`/`PutObject`/`DeleteObject`/`ListBucket` on the bucket.
3. This role runs with `clickhouse_s3_cold_storage_enabled: true` and
   clickhouse-server has restarted (the `template` task notifies the
   `restart clickhouse-server` handler automatically).
4. **Only then** does ops flip `CLICKHOUSE_STORAGE_POLICY_OVERRIDE` on the
   app (unset defaults to `'tiered'` per `runtime.exs` — set it to
   `disabled` explicitly for any deploy that precedes step 3).

Skipping the order in step 4 is the exact failure `storage-s3-tiered.xml.j2`'s
header warns about: a fresh `CREATE TABLE ... SETTINGS storage_policy =
'tiered'` against a server that has never defined the `tiered` policy fails
`NO_SUCH_POLICY`. This role cannot enforce that ordering across deploy
pipelines by itself — it can only guarantee that when it DOES define the
policy, the policy is on disk and loaded before the role returns.

## AWS vs OCI: the credential asymmetry is real, not a bug

`clickhouse_s3_cold_auth_mode` selects one of two mutually exclusive blocks in
`storage-s3-tiered.xml.j2`:

| Mode | Renders | Works on |
|---|---|---|
| `instance_role` | `<use_environment_credentials>true</use_environment_credentials>` | AWS only |
| `static_keys` (default) | `<access_key_id>`/`<secret_access_key>` | AWS and OCI |

ClickHouse's `s3` disk type only speaks the S3 API. On OCI, the only endpoint
that understands it is OCI Object Storage's **S3-compatibility API**
(`https://<namespace>.compat.objectstorage.<region>.oraclecloud.com/<bucket>/`),
and **that API does not accept OCI instance principals** — it requires
long-lived Customer Secret Keys (a static SigV4 access key/secret pair,
created under the OCI user's "Customer Secret Keys"). This is a documented
limitation of OCI's S3-compat surface, not something this role works around by
choice, and not something an OCI instance's own native-API instance-principal
support (used elsewhere for `oci os` CLI calls) changes — the S3-compat
endpoint is a separate auth surface. `clickhouse_s3_cold_auth_mode` therefore
defaults to `static_keys`: it's the only mode that works everywhere this role
might run. Set it to `instance_role` explicitly on AWS if you want the
node-IAM-role credential path instead of static keys there.

Do not attempt to make `instance_role` work on OCI — it cannot, and the
failure mode (silently falling back to no credentials, or the disk failing to
authenticate) is worse than requiring an explicit static-keys config.

### IAM/credential grants per provider

- **AWS, `instance_role`**: the node's IAM instance profile needs
  `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the
  cold-tier bucket. No static keys stored anywhere.
- **AWS or OCI, `static_keys`**: `clickhouse_s3_cold_access_key_id` /
  `clickhouse_s3_cold_secret_access_key` need the same four permissions —
  on AWS an IAM user's access key; on OCI a Customer Secret Key belonging to
  a user/policy scoped to the bucket's compartment.

## Variables

See `defaults/main.yaml` for the full list and inline documentation —
version, listen host, ports, data dir, memory ratio, allowed network CIDR,
and the cold-tier toggle/endpoint/auth-mode/credential vars.

## Not done here (deliberately out of scope)

- Provisioning the actual EC2/OCI compute node this role runs on, or tagging
  it so `mix ansible.setup` targets it (that's `mix terraform.build`'s
  `DatabaseKey`/`MonitoringKey` tag wiring — see
  `priv/ansible/setup/clickhouse.yaml` for the host group this role expects
  to exist).
- Creating the cold-tier bucket, its lifecycle policy, or the IAM/OCI
  credentials themselves — those are operator/Terraform actions, listed
  above as prerequisites.
- ClickHouse user/ACL management beyond the single `default` user the app
  connects as. Add a dedicated `users.d` fragment here if a second
  (e.g. migrate-only) ClickHouse user is ever needed to match
  `CLICKHOUSE_MIGRATE_URL_OVERRIDE`'s separate-credentials intent.
