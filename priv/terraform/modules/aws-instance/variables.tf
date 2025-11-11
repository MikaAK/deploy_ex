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

variable "enable_ebs" {
  description = "Enables instance to generate an Elastic Block Store volume for itself"
  type        = bool
  default     = false
  nullable    = false
}

variable "instance_ebs_primary_size" {
  description = "Root volume size in GB, default 8GB"
  type        = number
  default     = 8
  nullable    = false
}

variable "instance_ebs_secondary_size" {
  description = "EBS size, default 16GB"
  type        = number
  default     = 16
  nullable    = false
}

variable "instance_ebs_secondary_snapshot_id" {
  description = "EBS snapshot ID to restore from when creating new volume"
  type        = string
  default     = null
  nullable    = true
}

### Instances ###
#################

variable "instance_availability_zone" {
  description = "Instance availability zone"
  type        = string
  default     = null
  nullable    = true
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

variable "elb_instance_port" {
  description = "Changes the application port targeted by the load balancer"
  type        = number
  default     = 80
  nullable    = false
}

variable "elb_health_check_path" {
  description = "Changes the application path targeted by the load balancer health check"
  type        = string
  default     = ""
  nullable    = false
}

variable "elb_health_check_https_matcher" {
  description = "Changes the status codes for the load balancer health check"
  type        = string
  default     = "200-299"
  nullable    = false
}

variable "elb_health_check_matcher" {
  description = "Changes the status codes for the load balancer health check"
  type        = string
  default     = "200-299,301"
  nullable    = false
}

variable "elb_health_check_unhealthy_threshold" {
  description = "Changes the unhealthy threshold checks for the load balancer health check"
  type        = number
  default     = 2
  nullable    = false
}

variable "elb_health_check_healthy_threshold" {
  description = "Changes the healthy threshold checks for the load balancer health check"
  type        = number
  default     = 2
  nullable    = false
}

variable "elb_health_check_timeout" {
  description = "Changes the health check timeout"
  type        = number
  default     = 5
  nullable    = false
}

variable "elb_health_check_interval" {
  description = "Changes the health check interval"
  type        = number
  default     = 20
  nullable    = false
}

### Autoscaling ###
###################

variable "enable_autoscaling" {
  description = "Enables AWS Auto Scaling Group instead of fixed instance count"
  type        = bool
  default     = false
  nullable    = false
}

variable "autoscaling_min_size" {
  description = "Minimum number of instances in the Auto Scaling Group"
  type        = number
  default     = 1
  nullable    = false
}

variable "autoscaling_max_size" {
  description = "Maximum number of instances in the Auto Scaling Group"
  type        = number
  default     = 1
  nullable    = false
}

variable "autoscaling_desired_capacity" {
  description = "Desired number of instances in the Auto Scaling Group"
  type        = number
  default     = 1
  nullable    = false
}

variable "autoscaling_cpu_target_percent" {
  description = "Target CPU utilization percentage for autoscaling policy"
  type        = number
  default     = 60
  nullable    = false
}

variable "autoscaling_scale_in_cooldown" {
  description = "Cooldown period in seconds for scale-in actions"
  type        = number
  default     = 300
  nullable    = false
}

variable "autoscaling_scale_out_cooldown" {
  description = "Cooldown period in seconds for scale-out actions"
  type        = number
  default     = 300
  nullable    = false
}

variable "app_port" {
  description = "Port number for the application"
  type        = number
  default     = 4000
  nullable    = false
}

variable "use_custom_ami" {
  description = "Enable custom AMI lookup from SSM Parameter Store. Set to false to always use instance_ami directly."
  type        = bool
  default     = true
  nullable    = false
}
