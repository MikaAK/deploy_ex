output "release_bucket_name" {
  description = "Name of the s3 bucket releases will be stored in"
  value       = aws_s3_bucket.release_bucket.id
}

output "instance_id" {
  description = "ID of the EC2 instance"
  value       = { for p in sort(keys(var.learn_elixir_project)) : p => module.ec2_instance[p].instance_ids }
}

output "public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = { for p in sort(keys(var.learn_elixir_project)) : p => module.ec2_instance[p].public_ips }
}

