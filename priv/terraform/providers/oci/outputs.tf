output "vcn_id" {
  description = "VCN OCID"
  value       = oci_core_vcn.main.id
}

output "subnet_id" {
  description = "Public subnet OCID"
  value       = oci_core_subnet.public.id
}

output "instance_id" {
  description = "Compute instance OCID"
  value       = oci_core_instance.main.id
}

output "instance_public_ip" {
  description = "Public IP, or null when assign_public_ip is false"
  value       = oci_core_instance.main.public_ip
}

output "instance_private_ip" {
  description = "Private IP within the subnet"
  value       = oci_core_instance.main.private_ip
}

output "instance_state" {
  description = "Lifecycle state as reported by OCI"
  value       = oci_core_instance.main.state
}
