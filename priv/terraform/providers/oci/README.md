# OCI environment

An Oracle Cloud environment — VCN, internet gateway, route table, security list, public subnet,
one OCI compute instance per app entry in `var.<project>_project` (mirroring AWS's per-app
`module "ec2_instance" { for_each = ... }`), a release bucket, and the dynamic group/policy
instance principals need to reach it. Rendered by `mix terraform.build --provider oci` via
`DeployEx.Cloud.PrivFileSet` — non-`.eex` files here are copied as-is, `.eex` files render and
flatten onto the terraform root (`instance.tf.eex` -> `instance.tf`, etc).

The original single-instance skeleton this replaced was verified against a live tenancy: 6
resources created, instance reached RUNNING, all 6 destroyed, compartment confirmed empty. The
current multi-app shape has been verified with `tofu init`/`validate`/`plan` only — see the plan
doc's v21+ amendments for exact commands and output. **`tofu apply` has not been run against this
shape.**

## What's here vs. AWS

Deliberately minimal compared to the AWS `aws-instance` module — no EBS snapshot restore, no
autoscaling. Per-app instances support: instance count, shape, ocpus, memory, image OCID
(auto-detected if unset), boot volume size, public IP, ssh key, load balancer, and freeform tags.
Cloud-init / release bootstrapping (AWS's `cloud_init_data.yaml.tftpl`) is also not ported yet —
it needs the `oci` CLI instance-principal flow (Phase 3, `cli_adapter` in
`DeployEx.Cloud.Providers.Oci` is still `nil`), not the AMI-style `awscli` bootstrap AWS uses.

## Load balancer

Set `load_balancer = { enable = true, ... }` inside an app's entry in `<app>_project` and
`mix terraform.apply` provisions an OCI Network Load Balancer (`oci_network_load_balancer_*`) in
`modules/oci-instance/load_balancer.tf` — one NLB per LB-enabled app, listening on 80 (and 443
when `enable_https = true`) and forwarding to that app's instances.

```hcl
load_balancer = {
  enable            = true
  enable_https      = false
  reserved_ip_ocid  = null

  health_check = {
    path                = "/health"
    return_code         = 200
    https_return_code   = 200
    unhealthy_threshold = 3
    timeout             = 3
    interval            = 10
  }
}
```

**Gate divergence (D1):** AWS only creates a load balancer when
`enable && (instance_count > 1 || autoscaling.enable)` — OCI gates on `enable` alone. OCI has no
autoscaling and defaults `instance_count` to `1`, so copying AWS's gate would make
`load_balancer.enable = true` a silent no-op for the common single-instance case.

**Security posture (D3):** the NSG that opens 80/443 is created *per app*, attached to both the
NLB and the LB-enabled app's own instances — not a rule on the shared `network.tf` security list.
`network.tf` is untouched by this feature. Consequence: **ports 80/443 are reachable directly on
an LB-backed app's instances**, not only through the NLB — OCI's NSG and security-list rules are
additive (union), so the LB-scoped NSG opens those ports on the instance's VNIC regardless of the
NLB path. Apps without `load_balancer.enable = true` are unaffected.

**Portability (D6):** `health_check.return_code` and `health_check.https_return_code` are
OCI-only keys. An AWS-shaped `load_balancer` block runs unchanged on OCI, but an OCI block that
sets `return_code` / `https_return_code` is rejected by AWS's typed `variables.tf` — portability
is one-way (AWS -> OCI, not OCI -> AWS).

**Keys AWS has that OCI ignores**, and why:

| Key | Why ignored on OCI |
|---|---|
| `port` | Dead on AWS too — declared but never wired into a target group. OCI's listener is always 80/443. |
| `instance_port` | Same as above — always falls back to 80/443 on both providers. |
| `health_check.protocol` | AWS hardcodes `HTTP` on the 80 check and `HTTPS` on the 443 check. OCI derives the same thing: `HTTP`/`HTTPS` when `health_check.path` is set, `TCP` (connect-only) when it is not — OCI's health checker cannot be omitted the way AWS's can. |
| `health_check.matcher` / `health_check.https_matcher` | AWS accepts a status-code *range* string (`"200-299,301"`). OCI's `return_code` is a single number — not representable, so it is a distinct key rather than a lossy mapping. |
| `health_check.healthy_threshold` | OCI has one threshold (`retries`) that governs both directions — see `health_check.unhealthy_threshold` below. |

**Keys that map directly:**

| Key | Maps to |
|---|---|
| `health_check.unhealthy_threshold` | `health_checker.retries` — OCI's own docs describe this as the retry count before *and* after a state flip, covering both AWS thresholds |
| `health_check.timeout` | `health_checker.timeout_in_millis` (seconds × 1000) |
| `health_check.interval` | `health_checker.interval_in_millis` (seconds × 1000) |

An unset health-check key passes `null` and takes OCI's own provider default (3 retries, 3s
timeout, 10s interval) rather than transplanting AWS's defaults (2/5s/20s) — deliberate, to avoid
a second set of magic numbers to keep in sync across providers.

`reserved_ip_ocid` is OCI-only, with no AWS equivalent: an NLB's public IP is ephemeral by
default and can change on NLB replacement. Set it to a pre-created reserved public IP OCID to
pin the address DNS targets.

## Operator notes — adopting the load balancer on an existing tree

- **Never `--force` an adopted tree.** `mix terraform.build --force` discards hand-edited drift
  in `variables.tf` (including any `load_balancer` block you've already enabled) and can close
  public ingress mid-cutover. Rebuild without `--force`, then re-apply your `load_balancer`
  edits if the regenerated defaults collided with them.
- **Opt-in flags are part of tree identity.** `--clickhouse` / `--rabbitmq` (and any other
  opt-in rebuild flag) must be passed on *every* `terraform.build` run against a tree that
  already has those nodes — a bare rebuild plans their destruction.
- **The load-balancer enable bit lives in the regenerated default map.** Enabling it is declared
  drift against the generator's default output, the same way any other hand-edited
  `<app>_project` value is — expected, not a bug to chase.

## Use

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in — gitignored
tofu init
tofu plan
tofu apply
tofu destroy
```

Auth is an OCI API key (non-interactive, no browser). Generate and upload one with:

```bash
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
oci iam user api-key upload --user-id <user-ocid> --key-file ~/.oci/oci_api_key_public.pem \
  --region <HOME-region>
```

A freshly uploaded key takes a minute or two to propagate; `NotAuthenticated` immediately after
upload usually means "wait", not "wrong".

## OCI constraints that differ from AWS

Both of these failed mid-apply during development, with resources already created:

- **`dns_label` on a VCN is capped at 15 characters**, must be alphanumeric, and must start with a
  letter. AWS VPCs have no equivalent, so a project name that is fine on AWS breaks VCN creation
  here. `providers.tf` normalizes and clamps it rather than assuming the name fits.
- **OCI rejects every CIDR inside `0.0.0.0/8`.** The AWS habit of using `0.0.0.0/32` as a
  "matches nothing" sentinel is invalid. Absence is expressed by omitting the rule entirely — the
  SSH ingress rule is a `dynamic` block that produces nothing when `ssh_ingress_cidr` is empty.

Two more things worth knowing:

- **IAM writes go to the tenancy's HOME region**, which is often not where resources live.
  Creating compartments, API keys, dynamic groups or policies against the wrong region fails with
  `NotAllowed — "Please go to your home region"`.
- **Some regions have exactly one availability domain** (ap-seoul-1, ap-chuncheon-1), so there is
  no multi-AD spread to configure.

## Release bucket + instance principals

`bucket.tf` creates one `oci_objectstorage_bucket` for releases — there is no separate
release-state bucket, since `release-state` is just an object prefix inside this same bucket
(matches `priv/ansible/roles/deploy_node/defaults/main.yaml`). `iam.tf` creates the dynamic
group (matches every instance in `compartment_ocid`) and policy (read on the bucket, manage on
its `release-state/*` prefix) instances need to read/write it via instance principals — no
Customer Secret Keys involved. Both IAM resources use the `oci.home` provider alias (see next
section) since they are IAM writes.

## State

Local state, deliberately. This is a throwaway environment; remote state belongs with the real
backend work rather than pointing at an existing bucket.
