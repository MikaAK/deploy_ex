output "instance_ids" {
  description = "ID of the EC2 instance"
  value       = aws_instance.ec2_instance.*.id
}

output "public_ips" {
  description = "Public IP address of the EC2 instance"
  value       = aws_eip_association.ec2_eip_association.*.public_ip
}
