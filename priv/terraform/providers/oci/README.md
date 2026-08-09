# OCI basic environment

A minimal Oracle Cloud environment — VCN, internet gateway, route table, security list, public
subnet, and one compute instance. It exists to prove `tofu apply` and `tofu destroy` work against
OCI end to end. **It is not wired into deploy_ex yet**: nothing renders it, no Mix task drives it,
and it deploys no application.

Verified against a live tenancy: 6 resources created, instance reached RUNNING, all 6 destroyed,
compartment confirmed empty.

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

## State

Local state, deliberately. This is a throwaway environment; remote state belongs with the real
backend work rather than pointing at an existing bucket.
