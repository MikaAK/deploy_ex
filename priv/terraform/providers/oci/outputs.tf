output "vcn_id" {
  description = "VCN OCID"
  value       = oci_core_vcn.main.id
}

output "subnet_id" {
  description = "Public subnet OCID"
  value       = oci_core_subnet.public.id
}

output "ssh_nsg_id" {
  description = "OCID of the network security group mix deploy_ex.ssh.authorize manages"
  value       = oci_core_network_security_group.ssh.id
}

output "instance_ids" {
  description = "Compute instance OCIDs, keyed by app name"
  value       = { for app, mod in module.oci_instance : app => mod.instance_ids }
}

output "instance_public_ips" {
  description = "Public IPs, keyed by app name (empty when assign_public_ip is false)"
  value       = { for app, mod in module.oci_instance : app => mod.public_ips }
}

output "instance_private_ips" {
  description = "Private IPs within the subnet, keyed by app name"
  value       = { for app, mod in module.oci_instance : app => mod.private_ips }
}

output "release_bucket_name" {
  description = "Name of the release bucket"
  value       = oci_objectstorage_bucket.releases.name
}
