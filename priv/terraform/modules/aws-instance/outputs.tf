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

output "ipv6_addresses" {
  description = "IPv6 addresses of the EC2 instance"
  value       = aws_instance.ec2_instance.*.ipv6_addresses
}

output "load_balancer_dns_name" {
  description = "Load balancer DNS name"
  value       = aws_lb.ec2_lb.*.dns_name
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling Group"
  value       = var.enable_autoscaling ? aws_autoscaling_group.ec2_asg[0].name : null
}

output "autoscaling_group_arn" {
  description = "ARN of the Auto Scaling Group"
  value       = var.enable_autoscaling ? aws_autoscaling_group.ec2_asg[0].arn : null
}

output "is_autoscaling" {
  description = "Whether this instance group is using autoscaling"
  value       = var.enable_autoscaling
}
