resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${local.name_prefix}-vcn"

  # OCI caps dnsLabel at 15 chars, must be alphanumeric, and must start with a letter — none of
  # which AWS imposes on a VPC. A project name that is fine on AWS silently breaks VCN creation
  # here, so this normalizes rather than assuming the name already fits.
  dns_label = local.vcn_dns_label

  freeform_tags = local.common_tags
}

resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.name_prefix}-igw"
  enabled        = true

  freeform_tags = local.common_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.name_prefix}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  freeform_tags = local.common_tags
}

# OCI security lists are stateful, so only ingress needs enumerating for inbound flows.
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.name_prefix}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # No SSH rule at all when no CIDR is supplied. OCI rejects any CIDR inside 0.0.0.0/8, so the
  # AWS trick of using 0.0.0.0/32 as a "matches nothing" sentinel is invalid here — absence has
  # to be expressed by omitting the rule. protocol 6 is TCP.
  dynamic "ingress_security_rules" {
    for_each = var.ssh_ingress_cidr == "" ? [] : [var.ssh_ingress_cidr]

    content {
      source   = ingress_security_rules.value
      protocol = "6"

      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  freeform_tags = local.common_tags
}

# Holds the SSH ingress rule `mix deploy_ex.ssh.authorize` toggles. A network security group
# rather than a second security list: `oci network nsg rules add`/`remove` operate on individual
# rules by content or ID, so the whitelist toggle never has to read the full rule set and write
# it back the way `oci_core_security_list` above would require. No default rules here — the
# security list already grants open egress and any static SSH CIDR to every instance in the
# subnet; this NSG exists solely for the dynamic per-run rule. See
# `DeployEx.Cloud.OciSecurityGroup` for the client that manages it.
resource "oci_core_network_security_group" "ssh" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.name_prefix}-nsg"

  freeform_tags = local.common_tags
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.subnet_cidr
  display_name               = "${local.name_prefix}-subnet"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = !var.assign_public_ip

  freeform_tags = local.common_tags
}
