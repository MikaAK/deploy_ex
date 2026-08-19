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
