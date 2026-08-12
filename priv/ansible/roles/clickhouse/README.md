# clickhouse

> **STATUS: NOT WORKING END TO END. Do not expect this role to leave you with a
> serving ClickHouse.**
>
> MEASURED 2026-08-12 against a live OCI Ubuntu 24.04 host: the packages install
> correctly, but `clickhouse-server` never reaches `active` under systemd. It
> crash-loops — `systemctl is-active` reports `activating`, the restart counter
> climbs, port 9000 refuses connections, and the journal shows:
>
> ```
> Supervising process N which is not our child.
> Killing process N with signal SIGKILL.
> Failed with result 'protocol'.
> ```
>
> Ruled out, each by experiment rather than by reasoning:
>
> | hypothesis | result |
> |---|---|
> | this role's `config.d/listen.xml` | NOT the cause — reproduces with the file removed |
> | `Type=notify` handshake mismatch | NOT fixed by a `Type=simple` drop-in |
> | wrong user / directory permissions | NOT the cause — runs fine in the foreground AS `clickhouse`; data, log and config dirs are all owned `clickhouse:clickhouse` |
> | broken or partial install | NOT the cause — 24.8.14.39 installed and runs standalone |
>
> The fault therefore sits in the ClickHouse 24.8 deb's packaged unit interacting
> with Ubuntu 24.04 systemd, not in what this role writes — but the role's job is
> a serving database, so it is unfinished until that is resolved. Likely next
> steps: ClickHouse's official install script instead of the apt repo, or a unit
> override matching how the binary actually forks.
>
> CONFIRMED working: the version pin (24.8.14.39 installed), the `clickhouse`
> system user and group, `users.d/zz-allow-default-network.xml` rendering, and
> the cold tier staying OFF by default (`config.d` holds only `listen.xml`).
> Everything else below — including the loopback `<networks>` entries — is
> UNVERIFIED, because the server never stayed up long enough to test it.

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
