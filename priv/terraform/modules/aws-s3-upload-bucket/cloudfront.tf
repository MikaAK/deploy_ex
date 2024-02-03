locals {
  // ID for Managed-CachingOptimized
  // https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html#attaching-managed-cache-policies
  managed_caching_optimized = "658327ea-f89d-4fab-a63d-7e88639e58f6"

  # full_cdn_domain  = "${var.cdn_subdomain}.${var.cdn_domain}"
}

resource "aws_secretsmanager_secret" "cdn_public_key" {
  count = var.enable_cdn ? 1 : 0

  name = "${var.environment}/${var.name}/cdn/public-key"
}

data "aws_secretsmanager_secret_version" "cdn_public_key" {
  count = var.enable_cdn ? 1 : 0

  secret_id = aws_secretsmanager_secret.cdn_public_key[0].id
}

resource "aws_cloudfront_public_key" "cdn" {
  count = var.enable_cdn ? 1 : 0

  comment     = "Key for ${var.environment} CDN"
  encoded_key = data.aws_secretsmanager_secret_version.cdn_public_key[0].secret_string
  name        = "${var.environment}-key"

  lifecycle {
    ignore_changes = [encoded_key]
  }
}

# If you see the following error:
# PublicKeyInUse: The Cloudfront public key is currently associated with either Key Group or a field level encryption profile.
# Please disassociate the key before deleting.
#
# You need to manually delete the key group in the AWS Console
# https://github.com/hashicorp/terraform-provider-aws/issues/19093
resource "aws_cloudfront_key_group" "cdn" {
  count = var.enable_cdn ? 1 : 0

  comment = "Key Group for ${var.environment} CDN"
  items   = [aws_cloudfront_public_key.cdn[0].id]
  name    = "${var.environment}-key-group"
}

module "aws_s3_upload_bucket_cloudfront_cdn" {
  count = var.enable_cdn ? 1 : 0

  source  = "terraform-aws-modules/cloudfront/aws"
  version = "3.2.1"

  aliases = [] # [local.full_cdn_domain]

  comment             = "CDN for ${var.environment}"
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_All"
  retain_on_delete    = false
  wait_for_deployment = false

  create_origin_access_identity = true
  create_origin_access_control  = true

  origin_access_identities = {
    bucket = "${var.environment}"
  }

  origin = {
    bucket = {
      domain_name = module.aws_s3_upload_bucket.s3_bucket_bucket_domain_name
      origin_access_control = local.bucket_name
    }
  }

  origin_access_control = {
    "${local.bucket_name}" : {
      "description" : "Origin Access Control for ${local.bucket_name}}",
      "origin_type" : "s3",
      "signing_behavior" : "always",
      "signing_protocol" : "sigv4"
    }
  }

  default_cache_behavior = {
    target_origin_id       = "bucket"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods      = ["GET", "HEAD"]
    cached_methods       = ["GET", "HEAD"]
    compress             = true
    query_string         = true
    cache_policy_id      = local.managed_caching_optimized
    use_forwarded_values = false

    trusted_key_groups = [aws_cloudfront_key_group.cdn[0].id]
  }

  ordered_cache_behavior = [{
    path_pattern           = "/public/*"
    target_origin_id       = "bucket"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods      = ["GET", "HEAD"]
    cached_methods       = ["GET", "HEAD"]
    compress             = true
    query_string         = true
    cache_policy_id      = local.managed_caching_optimized
    use_forwarded_values = false
  }]

#   viewer_certificate = {
#     acm_certificate_arn = module.acm[0].acm_certificate_arn
#     ssl_support_method  = "sni-only"
#   }

  tags = merge({
    Name          = format("%s CDN", replace(var.name, "_", " "))
    Group         = var.resource_group
    Environment   = var.environment
    Type          = "Self Made"
  }, var.tags)
}

# module "acm" {
#   count = var.enable_cdn ? 1 : 0

#   source  = "terraform-aws-modules/acm/aws"
#   version = "~> 4.0"

#   domain_name               = local.full_cdn_domain
#   zone_id                   = var.cdn_zone_id
#   subject_alternative_names = [var.cdn_domain]
# }

# module "cdn_records" {
#   count = var.enable_cdn ? 1 : 0

#   source  = "terraform-aws-modules/route53/aws//modules/records"
#   version = "~> 2.0"

#   zone_id = var.cdn_zone_id

#   records = [
#     {
#       name = var.cdn_subdomain
#       type = "A"
#       alias = {
#         name    = module.cdn[0].cloudfront_distribution_domain_name
#         zone_id = module.cdn[0].cloudfront_distribution_hosted_zone_id
#       }
#     },
#   ]
# }
