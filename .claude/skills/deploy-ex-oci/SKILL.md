---
name: deploy-ex-oci
description: "Use when running deploy_ex against Oracle Cloud (OCI) — mix tasks with --provider oci, cloud_provider :oci config, the oci CLI, OCIDs, compartments, tenancy, instance principals, dynamic groups, VCN/subnet/security lists, OCI object storage, or OCI-flavored errors like NotAuthenticated, NotAuthorizedOrNotFound, 403 from ExAws against an OCI endpoint. Also use when deciding whether an operation is even possible on OCI yet, tearing down OCI resources, or debugging an OCI node that AWS habits (instance profile, journalctl-only, 0.0.0.0/32 sentinel CIDRs) would misdiagnose. NOT for AWS operations — deploy-ex-ops and deploy-ex-infra cover those."
---

# deploy_ex on Oracle Cloud (OCI)

OCI is the second provider behind the `DeployEx.Cloud` seam. Everything OCI goes through the `oci` CLI (`DeployEx.Cloud.OciCli`) — there is no usable Elixir SDK, and ExAws cannot substitute: its partition table is compile-time so an OCI region can never be registered, and signing with an AWS region against an OCI endpoint returns 403.

## What works vs what doesn't

| Capability | Status |
|------------|--------|
| `object_store` (`Cloud.OciObjectStore`) | Filled — releases/state via oci CLI |
| `security` (`Cloud.OciSecurityGroup`) | Filled |
| `inventory` | Static — `ansible.build` queries the oci CLI, renders `oci.yaml` snapshot |
| `machine` | `DeployEx.Cloud.OciMachine` — run/terminate/describe/list instances, `await_running`, via the `oci` CLI (compartment-scoped) |
| `infrastructure` | `DeployEx.Cloud.OciInfrastructure` — config-driven subnet/image/key material for the loadtest path |
| `cli_adapter` | `DeployEx.Cloud.OciCli` — shared shell runner (session-token auth aware, shell-quoted args) |

Verified live: `terraform.build/init/plan --provider oci`, `ansible.build`, `ansible.ping`, `ansible.setup`, `deploy_ex.upload`. Roughly 26 mix tasks remain AWS-only (`ssh`, `instance.*`, `restart_app`, `find_nodes`, `qa.*`, `autoscale.*`, load balancer, EBS snapshots, DB dump/restore) — check `capabilities/0` in `lib/deploy_ex/cloud/providers/oci.ex` before promising a task works on OCI.

`deploy_ex.load_test.*` (all accept `--provider oci`, validated — an unrecognized value raises rather than silently running against AWS):

| Task | Under `--provider oci` |
|------|------|
| `create_instance` / `destroy_instance` | Wired through `OciMachine` (launch/terminate in the configured compartment; `await_running` lifecycle gate). Live-verified in S3. |
| `exec` | Runner resolution via `OciMachine.describe_instance`; prometheus discovery is AWS-only (warns + runs without metrics export under `:oci`) |
| `upload` | Runner resolution via `OciMachine`; scp/ssh use the descriptor's `default_ssh_user` (`ubuntu`) |
| `list` | State-op paths (`fetch_all_runners`) route through `object_store` and work once `:oci` `release_bucket` is configured; the EC2-fallback path (`find_runners_from_ec2`) errors `:not_implemented` under any non-AWS provider by design — it must never print AWS's leftover runners as OCI's |
| `init` | Provider-agnostic (writes local files only) |

## Configuration

```elixir
config :deploy_ex,
  cloud_provider: :oci,
  oci: [
    region: "ap-seoul-1",
    home_region: "ap-chuncheon-1",
    compartment_id: "ocid1.compartment...",
    namespace: "...",
    release_bucket: "...",
    resource_group: "...",
    profile: "DEFAULT"
  ]
```

The `:oci` namespace is validated strictly (NimbleOptions) — a typo'd key fails at task start. All keys optional, but `release_bucket` and `resource_group` are read eagerly (not lazily defaulted like their AWS flat-key equivalents) by anything going through `Cloud.release_bucket/1` / `Cloud.resource_group/1` — e.g. `deploy_ex.load_test.*`'s state ops — and left unset they error loudly (`{:error, %ErrorMessage{code: :bad_request}}`) rather than silently sending an empty container/tag name to the `oci` CLI. Read via `Config.oci_setting(key)` (a thin wrapper over the generic `Config.provider_setting(:oci, key)`); task opts carry an `oci_` prefix (`--oci-region`) so a bare AWS `:region` can never leak in as the OCI region. Full key list: `@config_schema` in `lib/deploy_ex/cloud/providers/oci.ex`. The loadtest machine path additionally REQUIRES: `compartment_id`, `availability_domain`, `subnet_id`, `base_image`, `shape`, `ssh_public_key` — each errors `bad_request` naming the key when unset.

## Auth

- `OCI_CLI_AUTH=api_key` on workstation/CI, `instance_principal` on OCI instances (the EC2-instance-profile analogue). Session-token auth needs a browser and expires — avoid.
- API key setup commands: `priv/terraform/providers/oci/README.md`. A freshly uploaded key takes 1–2 min to propagate — `NotAuthenticated` right after upload means *wait*, not *wrong*.
- **IAM writes go to the tenancy HOME region** (e.g. `ap-chuncheon-1`), not the resource region. Dynamic groups + policies for instance principals live in the **tenancy root**, often outside your compartment permissions.
- Policy conditions: `target.object.name = 'release-state/*'` — `target.object.name_prefix` is NOT a real OCI policy variable.
- Terraform state rides OCI's **S3-compat endpoint** (no native OCI backend), which needs a Customer Secret Key — a different auth surface that rejects instance principals. Same for ClickHouse's `s3` disk. Native object storage calls need neither.

## OCI constraints that break AWS habits

- VCN `dns_label`: ≤15 chars, alphanumeric, starts with a letter — long project names fail mid-apply. `providers.tf` clamps it.
- **Every CIDR inside `0.0.0.0/8` is rejected.** No `0.0.0.0/32` "matches nothing" sentinel — omit the rule instead (the SSH ingress rule is a `dynamic` block).
- OCI filters traffic **between instances in the same subnet** — intra-VCN rules must be explicit in the security list.
- OCI Ubuntu images ship a **default host firewall that blocks app ports** — the setup playbook opens it; a hand-built node won't have that.
- SSH user is `ubuntu` (no `admin` user like AWS Debian images).
- Releases must be built on the **target arch** — qemu segfaults running the BEAM under amd64 emulation on arm64 — and must **bundle ERTS** (nodes have no system BEAM).

## oci CLI usage

`OciCli.run("os object list ...", opts)` / `run_json/2`. The CLI prints **nothing** (not `{"data": []}`) when a list matches no resources — `run_json` maps that to an empty map. When verifying manually, use `--output table`: with JSON, an empty result and a parse failure look identical.

## Teardown ordering

`oci compute instance terminate` rejects `--wait-for-state` combined with `--force`, and network deletes fail while the VNIC is still detaching. Order: terminate → wait for TERMINATED → subnet → security list → route table → IGW → VCN. Verify each step with `--output table`.

## Ansible on OCI

`mix ansible.build --provider oci --force` — **always `--force`**: the task prompts before overwriting templated files, and non-interactively (piped stdin) it silently skips them and still exits 0. Roles sync by directory copy regardless, which masks the stale templates.

OCI nodes get provider role overrides from `priv/ansible/providers/oci/roles/` — `oci_cli` replaces `awscli` in setup, and `deploy_node` has an OCI-specific variant; `save_ami` is skipped (AWS-only).

Diagnose daemons from **their own log**, not systemd's — `Failed with result 'protocol'` is identical for a config parse error and a `Type=notify` mismatch.

## References

- `priv/terraform/providers/oci/README.md` — template set, verified-live status, API key setup
- `priv/ansible/providers/oci/README.md` — inventory generator
- `lib/deploy_ex/cloud/oci_cli.ex` — CLI wrapper, error classification
