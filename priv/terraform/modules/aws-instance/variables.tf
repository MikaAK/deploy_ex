variable "instance_count" {
  description = "Instance count, default 1"
  type        = number
  default = 1
}

variable "instance_type" {
  description = "Instance type, t3.nano for example"
  type        = string
  default = "t3.nano"
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
  type = string
}
