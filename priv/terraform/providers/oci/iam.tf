# Instance principal access to the release bucket.
#
# Dynamic groups and policies are IAM writes — MEASURED to always land in the tenancy's HOME
# region regardless of which region the resources they reference live in (see B3 in
# docs/superpowers/plans/2026-08-03-multi-cloud-oci.md). Both resources below use the `oci.home`
# provider alias declared in providers.tf.

resource "oci_identity_dynamic_group" "instances" {
  provider = oci.home

  compartment_id = var.tenancy_ocid
  name           = "${var.project_name}-${var.environment}-instances"
  description    = "Instances in the ${var.project_name} ${var.environment} compartment (release bucket access)"

  # Matches every instance in the resource compartment. Freeform-tag-based matching rules are
  # not an option — OCI dynamic group rules only match defined tags, not freeform tags.
  matching_rule = "ALL {instance.compartment.id = '${var.compartment_ocid}'}"

  freeform_tags = local.common_tags
}

# Policy is attached at the resource compartment (not the tenancy root) so it grants no more
# than instances in this project actually need — least-privilege scope for the bucket they
# read releases from and write release-state markers to.
resource "oci_identity_policy" "instance_release_bucket_access" {
  provider = oci.home

  compartment_id = var.compartment_ocid
  name           = "${var.project_name}-${var.environment}-release-bucket-access"
  description    = "Lets ${var.project_name} ${var.environment} instances read releases and write release-state"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.instances.name} to read objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${var.release_bucket_name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.instances.name} to manage objects in compartment id ${var.compartment_ocid} where all {target.bucket.name = '${var.release_bucket_name}', target.object.name = 'release-state/*'}",
  ]

  freeform_tags = local.common_tags
}
