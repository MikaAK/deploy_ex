resource "oci_core_instance" "main" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${local.name_prefix}-0"
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  source_details {
    source_type = "image"
    source_id   = var.instance_image_ocid
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = var.assign_public_ip
    display_name     = "${local.name_prefix}-vnic"
    hostname_label   = "node0"
  }

  # ssh_authorized_keys is omitted entirely when no key is supplied — passing an empty string
  # makes the instance unreachable with no indication why.
  metadata = var.ssh_public_key == "" ? {} : { ssh_authorized_keys = var.ssh_public_key }

  freeform_tags = merge(local.common_tags, {
    "InstanceGroup" = "${replace(var.project_name, "-", "_")}_${var.environment}"
    "Name"          = "${local.name_prefix}-0"
  })
}
