output "instance_ids" {
  description = "OCIDs of the created instances"
  value       = oci_core_instance.main[*].id
}

output "public_ips" {
  description = "Public IPs of the created instances"
  value       = oci_core_instance.main[*].public_ip
}

output "private_ips" {
  description = "Private IPs of the created instances"
  value       = oci_core_instance.main[*].private_ip
}

output "load_balancer_public_ips" {
  description = "Public IPs of the load balancer. Empty list when enable_load_balancer is false."
  value = [
    for ip in flatten(oci_network_load_balancer_network_load_balancer.main[*].ip_addresses) : ip.ip_address
    if ip.is_public
  ]
}
