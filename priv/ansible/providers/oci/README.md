# OCI ansible file set

Selected by `DeployEx.Cloud.PrivFileSet` when `mix ansible.build --provider oci` (or
`config :deploy_ex, cloud_provider: :oci`) runs. Flattens onto the ansible root exactly
like the terraform provider set — `providers/oci/ansible.cfg.eex` becomes `ansible.cfg`,
`providers/oci/oci.yaml.eex` becomes `oci.yaml`.

- `ansible.cfg.eex` — same shape as the root AWS config, except `remote_user = ubuntu`
  (OCI's Ubuntu images have no `admin` user) and `inventory = ./oci.yaml`. No `[inventory]`
  section: the static file parses through ansible-core's built-in `yaml` plugin, so nothing
  needs enabling.
- `oci.yaml.eex` — static inventory render template. `ansible.build.ex` queries the `oci`
  CLI directly (no `oracle.oci` collection dependency) for running instances in the
  configured compartment, filters to this project (`Group` freeform tag), and composes
  host groups + hostvars from the same four tag keys the AWS `aws_ec2` plugin's
  `keyed_groups` reads (`MonitoringKey`, `InstanceGroup`, `DatabaseKey`, `QaNode`) so
  playbooks and `--limit` targeting work unmodified across providers.

Everything else (roles, setup playbooks, playbook/group_vars templates) is shared with AWS
and lives at the ansible root — OCI has no role variants yet, so it gets those files
byte-identical.

**Static, not dynamic**: unlike `aws_ec2.yaml.eex`, this is a snapshot, not a live plugin
query. Regenerate it (`mix ansible.build`) after any instance create/scale/terminate or
`--limit`/group targeting will miss the change.
