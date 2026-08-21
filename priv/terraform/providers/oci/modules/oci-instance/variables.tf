### General ###
###############

variable "resource_group" {
  description = "Group tag for all resources"
  type        = string
  nullable    = false
}

variable "environment" {
  description = "Environment tag value"
  type        = string
  nullable    = false
}

variable "compartment_ocid" {
  description = "Compartment OCID instances are created in"
  type        = string
  nullable    = false
}

variable "availability_domain" {
  description = "Availability domain name"
  type        = string
  nullable    = false
}

variable "subnet_id" {
  description = "Subnet OCID instances attach to"
  type        = string
  nullable    = false
}

variable "nsg_ids" {
  description = "Network security group OCIDs attached to each instance's VNIC"
  type        = list(string)
  default     = []
  nullable    = false
}

variable "instance_name" {
  description = "Instance name itself"
  type        = string
  nullable    = false
}

variable "tags" {
  description = "Freeform tags to merge onto every resource"
  type        = map(any)
  default     = {}
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

variable "instance_shape" {
  description = "Flex shape, default VM.Standard.E5.Flex"
  type        = string
  default     = "VM.Standard.E5.Flex"
  nullable    = false
}

variable "instance_ocpus" {
  description = "OCPU count for the flex shape, default 1"
  type        = number
  default     = 1
  nullable    = false
}

variable "instance_memory_gbs" {
  description = "Memory in GB for the flex shape, default 8"
  type        = number
  default     = 8
  nullable    = false
}

variable "instance_image_ocid" {
  description = "Image OCID"
  type        = string
  nullable    = false
}

variable "boot_volume_size_gbs" {
  description = "Boot volume size in GB, default 50 (OCI's minimum)"
  type        = number
  default     = 50
  nullable    = false
}

variable "assign_public_ip" {
  description = "Whether instances get a public IP"
  type        = bool
  default     = true
  nullable    = false
}

variable "ssh_public_key" {
  description = "Public key injected into the instances. Empty installs no key, making them unreachable by SSH."
  type        = string
  default     = ""
  nullable    = false
}

### Load balancer ###
######################

variable "vcn_id" {
  description = "VCN OCID the load-balancer NSG attaches to. Only used when enable_load_balancer is true."
  type        = string
  default     = ""
  nullable    = false
}

variable "enable_load_balancer" {
  description = "Whether to create a network load balancer for this app. Gates on this flag alone, unlike AWS's enable_elb && (instance_count > 1 || autoscaling) — OCI has no autoscaling and instance_count defaults to 1, so copying AWS's gate would make the flag a silent no-op for the common case."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_load_balancer_https" {
  description = "Whether to also create the 443 backend set, backend, and listener"
  type        = bool
  default     = true
  nullable    = false
}

variable "load_balancer_health_check_path" {
  description = "HTTP(S) health check path. Empty performs a TCP connect check instead of an HTTP(S) one."
  type        = string
  default     = ""
  nullable    = false
}

variable "load_balancer_health_check_return_code" {
  description = "Expected HTTP return code for the 80 health check when load_balancer_health_check_path is set. Unset takes 200."
  type        = number
  default     = null
}

variable "load_balancer_health_check_https_return_code" {
  description = "Expected HTTP return code for the 443 health check when load_balancer_health_check_path is set. Unset takes 200."
  type        = number
  default     = null
}

variable "load_balancer_health_check_retries" {
  description = "Health check retries before a backend is marked unhealthy. Unset takes the provider default (3)."
  type        = number
  default     = null
}

variable "load_balancer_health_check_timeout_seconds" {
  description = "Health check timeout in seconds. Unset takes the provider default (3s)."
  type        = number
  default     = null
}

variable "load_balancer_health_check_interval_seconds" {
  description = "Health check interval in seconds. Unset takes the provider default (10s)."
  type        = number
  default     = null
}

variable "reserved_ip_ocid" {
  description = "OCID of a reserved public IP to attach to the NLB. Unset leaves the public IP ephemeral."
  type        = string
  default     = null
}
