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

Deliberately minimal compared to the AWS `aws-instance` module — no load balancer, no EBS
snapshot restore, no autoscaling. Per-app instances support: instance count, shape, ocpus,
memory, image OCID (auto-detected if unset), boot volume size, public IP, ssh key, and freeform
tags. Cloud-init / release bootstrapping (AWS's `cloud_init_data.yaml.tftpl`) is also not ported
yet — it needs the `oci` CLI instance-principal flow (Phase 3, `cli_adapter` in
`DeployEx.Cloud.Providers.Oci` is still `nil`), not the AMI-style `awscli` bootstrap AWS uses.

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
