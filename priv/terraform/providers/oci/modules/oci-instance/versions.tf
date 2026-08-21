# Explicit on purpose: without this, a child module that only implies its provider from a
# resource-type prefix (oci_core_instance -> "oci") falls back to the LEGACY hashicorp/oci
# registry namespace instead of inheriting the root's oracle/oci requirement — MEASURED,
# `tofu init` tries to resolve both and downloads hashicorp/oci alongside oracle/oci.
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }
}
