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
