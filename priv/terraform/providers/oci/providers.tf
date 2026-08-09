terraform {
  required_version = ">= 1.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }

  # Local state on purpose. This is a throwaway environment for proving apply/destroy;
  # remote state lands with the real Phase 2 backend work.
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = pathexpand(var.private_key_path)
  region           = var.region
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Strip everything OCI disallows, then clamp to the 15-char limit.
  vcn_dns_label = substr(
    lower(replace(local.name_prefix, "/[^A-Za-z0-9]/", "")),
    0,
    15
  )

  common_tags = {
    "Group"       = var.resource_group
    "Environment" = var.environment
    "ManagedBy"   = "DeployEx"
  }
}
