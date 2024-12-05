output "endpoint" {
  description = "Database endpoint"
  value       = aws_db_instance.rds_database.endpoint
}

output "address" {
  description = "Database address"
  value       = aws_db_instance.rds_database.address
}

output "port" {
  description = "Database port"
  value       = aws_db_instance.rds_database.port
}

output "database_name" {
  description = "Database name"
  value       = aws_db_instance.rds_database.db_name
}

output "database_username" {
  description = "Database username"
  value       = aws_db_instance.rds_database.username
}

output "instance_class" {
  description = "RDS instance class"
  value       = aws_db_instance.rds_database.instance_class
}

output "multi_az" {
  description = "Whether the RDS instance is multi-AZ"
  value       = aws_db_instance.rds_database.multi_az
}

output "storage_type" {
  description = "Storage type of the RDS instance"
  value       = aws_db_instance.rds_database.storage_type
}

output "allocated_storage" {
  description = "Allocated storage in GB"
  value       = aws_db_instance.rds_database.allocated_storage
}
