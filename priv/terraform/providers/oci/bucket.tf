# Release bucket. There is no separate "release state" bucket — release-state is an object
# prefix inside this same bucket (see priv/ansible/roles/deploy_node/defaults/main.yaml
# release_state_prefix), matching the AWS shape exactly.
#
# NOTE: OCI has no equivalent of aws_s3_bucket's `force_destroy`. A destroy against a bucket
# holding releases fails with "409-BucketNotEmpty, Bucket ... is not empty" — MEASURED — and
# leaves the bucket behind after every other resource is already gone. Emptying it first is
# left as a deliberate operator step rather than automated: the AWS side force-destroys
# release history on teardown, and silently doing the same here would delete every release
# artifact plus the current_release/release_history markers with no confirmation.
#
# To tear down completely:
#   oci os object bulk-delete --bucket-name <name> --force
#   mix terraform.drop
resource "oci_objectstorage_bucket" "releases" {
  compartment_id = var.compartment_ocid
  namespace      = var.namespace
  name           = var.release_bucket_name

  freeform_tags = merge(local.common_tags, {
    Name = "Releases"
  })
}
