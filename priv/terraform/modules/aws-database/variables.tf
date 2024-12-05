### General ###
###############
variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
  nullable    = false
}

variable "resource_group" {
  description = "Resource group name for tagging"
  type        = string
  nullable    = false
}

variable "name" {
  description = "Name of the database"
  type        = string
  nullable    = false
}

### Authentication ###
#####################
variable "database_username" {
  description = "Master username for the RDS instance"
  type        = string
  nullable    = false
}

### Instance ###
###############
variable "instance_type" {
  description = "The instance type of the RDS instance"
  type        = string
  default     = "db.t3.micro"
  nullable    = false
}

### Storage ###
##############
variable "allocated_storage_gb" {
  description = "The allocated storage in gigabytes"
  type        = number
  default     = 20
  nullable    = false
}

variable "max_allocated_storage_gb" {
  description = "The maximum allocated storage in gigabytes for autoscaling"
  type        = number
  default     = 100
  nullable    = false
}

### Network ###
##############
variable "vpc_id" {
  description = "VPC ID where the RDS instance will be created"
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = "List of subnet IDs where RDS can be provisioned"
  type        = list(string)
  nullable    = false
}

variable "security_group_id" {
  description = "Security group ID for RDS instance"
  type        = string
  nullable    = false
}


### Backup ###
#############
variable "backup_retention_period" {
  description = "The days to retain backups for"
  type        = number
  default     = 7
  nullable    = false
}

variable "backup_window" {
  description = "The daily time range during which automated backups are created"
  type        = string
  default     = "03:00-04:00"
  nullable    = false
}

variable "maintenance_window" {
  description = "The window to perform maintenance in"
  type        = string
  default     = "Mon:04:00-Mon:05:00"
  nullable    = false
}

### High Availability ###
########################
variable "multi_az" {
  description = "Specifies if the RDS instance is multi-AZ"
  type        = bool
  default     = false
  nullable    = false
}

### Monitoring ###
#################
variable "performance_insights_retention_period_days" {
  description = "The amount of days to retain Performance Insights data"
  type        = number
  default     = 7
  nullable    = false
}

### Tags ###
###########
variable "tags" {
  description = "Tags to add to the various resources"
  type        = map(any)
  default     = {}
  nullable    = false
}
