# OCI Database with PostgreSQL — the managed-postgres analogue of the AWS RDS path.
# One DB system per resource_databases entry; an empty map (the default) creates nothing,
# so this needs no render-time gating the way the AWS template does.

resource "random_password" "psql_admin" {
  for_each = var.resource_databases

  length  = 32
  special = false
}

# The subnet security list only admits SSH, and OCI filters intra-subnet traffic too — the
# nodes reach postgres through this NSG, not through subnet membership.
resource "oci_core_network_security_group" "database" {
  count = length(var.resource_databases) > 0 ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.name_prefix}-database-nsg"

  freeform_tags = local.common_tags
}

resource "oci_core_network_security_group_security_rule" "database_ingress" {
  count = length(var.resource_databases) > 0 ? 1 : 0

  network_security_group_id = oci_core_network_security_group.database[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.vcn_cidr
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

# Regionally durable storage needs no availability domain and survives AD loss. The flex
# shape sizes via instance_ocpu_count/memory rather than a fixed-shape name. The admin
# password is generated into state — state is remote and private, matching the AWS
# random_password approach.
resource "oci_psql_db_system" "database" {
  for_each = var.resource_databases

  compartment_id = var.compartment_ocid
  display_name   = "${each.value.name}-${var.environment}"
  shape          = try(each.value.shape, "PostgreSQL.VM.Standard.E5.Flex")
  db_version     = try(each.value.db_version, "16")

  instance_ocpu_count         = try(each.value.instance_ocpu_count, 2)
  instance_memory_size_in_gbs = try(each.value.instance_memory_size_in_gbs, 32)

  credentials {
    username = each.value.database_username

    password_details {
      password_type = "PLAIN_TEXT"
      password      = random_password.psql_admin[each.key].result
    }
  }

  network_details {
    subnet_id = oci_core_subnet.public.id
    nsg_ids   = [oci_core_network_security_group.database[0].id]
  }

  storage_details {
    system_type           = "OCI_OPTIMIZED_STORAGE"
    is_regionally_durable = true
  }

  freeform_tags = local.common_tags
}

output "databases" {
  description = "Database Info"
  value = { for k in sort(keys(var.resource_databases)) : k => {
    "endpoint" : oci_psql_db_system.database[k].network_details[0].primary_db_endpoint_private_ip,
    "username" : var.resource_databases[k].database_username
  } }
}
