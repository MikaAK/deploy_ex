locals {
  lb_count       = var.enable_load_balancer ? 1 : 0
  lb_https_count = var.enable_load_balancer && var.enable_load_balancer_https ? 1 : 0
  lb_has_path    = var.load_balancer_health_check_path != ""

  lb_timeout_in_millis  = var.load_balancer_health_check_timeout_seconds == null ? null : var.load_balancer_health_check_timeout_seconds * 1000
  lb_interval_in_millis = var.load_balancer_health_check_interval_seconds == null ? null : var.load_balancer_health_check_interval_seconds * 1000
}

resource "oci_core_network_security_group" "load_balancer" {
  count = local.lb_count

  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "${local.kebab_instance_name}-lb-nsg"

  freeform_tags = merge({
    Name          = "${local.kebab_instance_name}-lb-nsg"
    Group         = var.resource_group
    InstanceGroup = local.snake_instance_name
    Environment   = var.environment
    ManagedBy     = "DeployEx"
  }, var.tags)
}

resource "oci_core_network_security_group_security_rule" "load_balancer_http" {
  count = local.lb_count

  network_security_group_id = oci_core_network_security_group.load_balancer[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "load_balancer_https" {
  count = local.lb_https_count

  network_security_group_id = oci_core_network_security_group.load_balancer[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_network_load_balancer_network_load_balancer" "main" {
  count = local.lb_count

  compartment_id = var.compartment_ocid
  display_name   = "${local.kebab_instance_name}-nlb"
  subnet_id      = var.subnet_id
  is_private     = false

  network_security_group_ids = oci_core_network_security_group.load_balancer[*].id

  # Unset (null) leaves the public IP EPHEMERAL — it can change on NLB replacement. Only wired
  # when the caller supplies an already-created reserved public IP OCID.
  dynamic "reserved_ips" {
    for_each = var.reserved_ip_ocid == null ? [] : [var.reserved_ip_ocid]

    content {
      id = reserved_ips.value
    }
  }

  freeform_tags = merge({
    Name          = "${local.kebab_instance_name}-nlb"
    Group         = var.resource_group
    InstanceGroup = local.snake_instance_name
    Environment   = var.environment
    ManagedBy     = "DeployEx"
  }, var.tags)
}

resource "oci_network_load_balancer_backend_set" "http" {
  count = local.lb_count

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.main[0].id
  name                     = "http"
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol           = local.lb_has_path ? "HTTP" : "TCP"
    port               = 80
    url_path           = local.lb_has_path ? var.load_balancer_health_check_path : null
    return_code        = local.lb_has_path ? coalesce(var.load_balancer_health_check_return_code, 200) : null
    retries            = var.load_balancer_health_check_retries
    timeout_in_millis  = local.lb_timeout_in_millis
    interval_in_millis = local.lb_interval_in_millis
  }
}

resource "oci_network_load_balancer_backend_set" "https" {
  count = local.lb_https_count

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.main[0].id
  name                     = "https"
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol           = local.lb_has_path ? "HTTPS" : "TCP"
    port               = 443
    url_path           = local.lb_has_path ? var.load_balancer_health_check_path : null
    return_code        = local.lb_has_path ? coalesce(var.load_balancer_health_check_https_return_code, 200) : null
    retries            = var.load_balancer_health_check_retries
    timeout_in_millis  = local.lb_timeout_in_millis
    interval_in_millis = local.lb_interval_in_millis
  }
}

resource "oci_network_load_balancer_backend" "http" {
  count = local.lb_count * var.instance_count

  backend_set_name         = oci_network_load_balancer_backend_set.http[0].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.main[0].id
  target_id                = oci_core_instance.main[count.index].id
  port                     = 80
}

resource "oci_network_load_balancer_backend" "https" {
  count = local.lb_https_count * var.instance_count

  backend_set_name         = oci_network_load_balancer_backend_set.https[0].name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.main[0].id
  target_id                = oci_core_instance.main[count.index].id
  port                     = 443
}

resource "oci_network_load_balancer_listener" "http" {
  count = local.lb_count

  name                     = "http"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.main[0].id
  default_backend_set_name = oci_network_load_balancer_backend_set.http[0].name
  port                     = 80
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_listener" "https" {
  count = local.lb_https_count

  name                     = "https"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.main[0].id
  default_backend_set_name = oci_network_load_balancer_backend_set.https[0].name
  port                     = 443
  protocol                 = "TCP"
}
