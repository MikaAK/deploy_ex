variable "environment" {
  type     = string
  nullable = false
}

variable "db_name" {
  type     = string
  nullable = false
}

variable "security_group_id" {
  type     = string
  nullable = false
}

variable "subnet_ids" {
  type     = list(string)
  nullable = false
}

variable "allocated_storage" {
  type     = number
  nullable = false
}
