# Release bucket. There is no separate "release state" bucket — release-state is an object
# prefix inside this same bucket (see priv/ansible/roles/deploy_node/defaults/main.yaml
# release_state_prefix), matching the AWS shape exactly.
resource "oci_objectstorage_bucket" "releases" {
  compartment_id = var.compartment_ocid
  namespace      = var.namespace
  name           = var.release_bucket_name

  freeform_tags = merge(local.common_tags, {
    Name = "Releases"
  })
}
