locals {
  snake_instance_name = lower(replace(var.instance_name, " ", "_"))
  kebab_instance_name = lower(replace(var.instance_name, " ", "-"))
}

resource "oci_core_instance" "main" {
  count = var.instance_count

  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.instance_name}-${var.environment}-${count.index}"
  shape                = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.instance_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = var.assign_public_ip
    display_name     = "${local.kebab_instance_name}-vnic-${count.index}"
    hostname_label   = "${local.kebab_instance_name}-${count.index}"
  }

  # ssh_authorized_keys is omitted entirely when no key is supplied — passing an empty string
  # makes the instance unreachable with no indication why.
  metadata = var.ssh_public_key == "" ? {} : { ssh_authorized_keys = var.ssh_public_key }

  freeform_tags = merge({
    Name          = "${var.instance_name}-${var.environment}-${count.index}"
    Group         = var.resource_group
    InstanceGroup = local.snake_instance_name
    Environment   = var.environment
    ManagedBy     = "DeployEx"
  }, var.tags)
}
