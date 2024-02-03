variable "name" {
  type        = string
  description = "Name for the s3 upload resources"
}

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

variable "enable_cdn" {
  type        = bool
  description = "Enables the CDN for the bucket"
  default     = false
}

variable "cdn_subdomain" {
  type        = string
  description = "CDN subdomain name"
  default     = null
}

variable "cdn_domain" {
  type        = string
  description = "CDN domain name"
  default     = null
}

variable "bucket_cors_allowed_origins" {
  type        = list(string)
  description = "Allowed origins for CORS"
  default     = []
}

variable "cdn_zone_id" {
  type        = string
  description = "CDN zone id"
  default     = null
}

variable "cdn_public_key_secret_name" {
  type        = string
  description = "AWS Secrets Manager secret name containing public CDN signing key."
  default     = null
}

variable "tags" {
  description = "Tags to add to the various resources"
  type        = map(any)
  default     = {}
}

