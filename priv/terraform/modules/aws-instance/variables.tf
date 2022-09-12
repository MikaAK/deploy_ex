variable "instance_ebs_secondary_size" {
  description = "EBS size, default 16GB"
  type        = number
  default     = 16
  nullable    = false
}

variable "instance_count" {
  description = "Instance count, default 1"
  type        = number
  default     = 1
  nullable    = false
}

variable "instance_type" {
  description = "Instance type, t3.nano for example"
  type        = string
  default     = "t3.nano"
  nullable    = false
}

variable "instance_group" {
  description = "Instance Group tag"
  type        = string
}

variable "instance_name" {
  description = "Instance name itself"
  type        = string
}

variable "environment" {
  description = "Environment Group tag"
  type        = string
}

# variable "enable_elastic_ip" {
#   description = "Enables instance to generate an elastic ip for itself"
#   type        = string
#   default     = true
# }

variable "security_group_id" {
  description = "Security group IDs for EC2 instances"
  type        = string
}

variable "subnet_id" {
  description = "Subnet IDs for EC2 instances"
  type        = string
}

variable "key_pair_key_name" {
  description = "PEM file name to use for the ec2 instances"
  type        = string
}
