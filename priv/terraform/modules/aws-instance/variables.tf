### General ###
###############
variable "resource_group" {
  description = "Instance Group tag"
  type        = string
  nullable    = false
}

variable "environment" {
  description = "Environment Group tag"
  type        = string
  nullable    = false
}

variable "security_group_id" {
  description = "Security group IDs for EC2 instances"
  type        = string
  nullable    = false
}

variable "private_ip" {
  description = "Private Static IP to use for the instances"
  type        = string
  default     = null
}

variable "disable_public_ip" {
  description = "Disables instance from generating a public ip for itself"
  type        = bool
  default     = false
  nullable    = false
}

variable "disable_ipv6" {
  description = "Disables instance from generating an IPv6 address"
  type        = bool
  default     = false
  nullable    = false
}

variable "subnet_ids" {
  description = "Subnet IDs for EC2 instances"
  type        = list(string)
  nullable    = false
}

variable "key_pair_key_name" {
  description = "PEM file name to use for the ec2 instances"
  type        = string
  nullable    = false
}

variable "enable_eip" {
  description = "Enables instance to generate an elastic ip for itself"
  type        = bool
  default     = false
  nullable    = false
}

variable "tags" {
  description = "Tags to add to the various resources"
  type        = map(any)
  default     = {}
  nullable    = false
}

### EBS ###
###########

variable "instance_ebs_secondary_size" {
  description = "EBS size, default 16GB"
  type        = number
  default     = 16
  nullable    = false
}

variable "enable_ebs" {
  description = "Enables instance to generate an elastic bean stalk volume for itself"
  type        = bool
  default     = false
  nullable    = false
}

### Instances ###
#################

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

variable "instance_name" {
  description = "Instance name itself"
  type        = string
  nullable    = false
}

variable "instance_ami" {
  description = "Instance AMI"
  type        = string
  nullable    = false
}


### Load Balancer ###
#####################
variable "enable_elb" {
  description = "Enables instance to generate an elastic load balancer for itself"
  type        = bool
  default     = false
  nullable    = false
}

variable "elb_port" {
  description = "Changes the load balancer port used in the loadbalancer url"
  type        = number
  default     = 80
  nullable    = false
}

variable "elb_instance_port" {
  description = "Changes the application port targeted by the load balancer"
  type        = number
  default     = 80
  nullable    = false
}

variable "enable_elb_https" {
  description = "Enables the load balancer to turn on http (defaults to true)"
  type        = bool
  default     = true
  nullable    = false
}
