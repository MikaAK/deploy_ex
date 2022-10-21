output "instance_ids" {
  description = "ID of the EC2 instance"
  value       = aws_instance.ec2_instance.*.id
}

output "elastic_ips" {
  description = "Elastic (Static) IP address of the EC2 instance"
  value       = aws_eip_association.ec2_eip_association.*.public_ip
}

output "public_ips" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.ec2_instance.*.public_ip
}

output "load_balancer_dns_name" {
  description = "Load balancer DNS name"
  value       = aws_lb.ec2_lb.*.dns_name
}
