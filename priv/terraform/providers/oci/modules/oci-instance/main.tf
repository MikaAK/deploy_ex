locals {
  snake_instance_name = lower(replace(var.instance_name, " ", "_"))
  kebab_instance_name = lower(replace(var.instance_name, " ", "-"))

  # Paravirtualized, not iscsi: OCI's VM.Standard Flex shapes attach a paravirtualized
  # volume directly, with no iscsiadm login step required inside the guest — the
  # device below is simply present once the attachment resource applies. iSCSI needs
  # `iscsiadm -m node -T <iqn> -p <ipv4>:3260 -l` run from inside the instance before
  # the device exists at all, which has no natural home in a Terraform-only module and
  # would leave a naive mount script finding no disk. iSCSI is only required for
  # bare-metal shapes, which this module does not provision.
  #
  # ASSUMED, not measured against a live instance (see cloud_init_data.yaml.tftpl and
  # the D1 report): /dev/oracleoci/oraclevdb is the value WE request via this
  # resource's own `device` argument on a paravirtualized attachment — the documented
  # OCI convention for the first data volume on an Oracle-provided Ubuntu image (the
  # oracle-cloud-agent block-volume service creates this path via udev). It has not
  # been observed on a booted host in this environment. If it is wrong, the prepare
  # script fails safe (waits, times out, exits 0 with no mount — the same `nofail`
  # shape as AWS's script) rather than mounting the wrong disk.
  block_volume_device = "/dev/oracleoci/oraclevdb"
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
    nsg_ids          = concat(var.nsg_ids, oci_core_network_security_group.load_balancer[*].id)
    assign_public_ip = var.assign_public_ip
    display_name     = "${local.kebab_instance_name}-vnic-${count.index}"
    hostname_label   = "${local.kebab_instance_name}-${count.index}"
  }

  # ssh_authorized_keys is omitted entirely when no key is supplied — passing an empty string
  # makes the instance unreachable with no indication why. user_data is likewise omitted
  # entirely when no block volume is requested, rather than shipping a no-op cloud-init
  # payload to every instance.
  metadata = merge(
    var.ssh_public_key == "" ? {} : { ssh_authorized_keys = var.ssh_public_key },
    var.enable_block_volume ? {
      user_data = base64encode(templatefile("${path.module}/cloud_init_data.yaml.tftpl", {
        device_path = local.block_volume_device
      }))
    } : {}
  )

  freeform_tags = merge({
    Name          = "${var.instance_name}-${var.environment}-${count.index}"
    Group         = var.resource_group
    InstanceGroup = local.snake_instance_name
    Environment   = var.environment
    ManagedBy     = "DeployEx"
  }, var.tags)
}

### Block Volume Start ###
###########################

resource "oci_core_volume" "data" {
  count = var.enable_block_volume ? var.instance_count : 0

  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${local.kebab_instance_name}-data-${var.environment}-${count.index}"
  size_in_gbs         = var.block_volume_size_gbs

  freeform_tags = merge({
    Name          = "${local.kebab_instance_name}-data-${var.environment}-${count.index}"
    Group         = var.resource_group
    InstanceGroup = local.snake_instance_name
    Environment   = var.environment
    ManagedBy     = "DeployEx"
  }, var.tags)
}

resource "oci_core_volume_attachment" "data" {
  count = var.enable_block_volume ? var.instance_count : 0

  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.main[count.index].id
  volume_id       = oci_core_volume.data[count.index].id
  device          = local.block_volume_device
  is_read_only    = false
}
