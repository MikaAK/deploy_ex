# Resource Buckets
resource "aws_s3_bucket" "bucket" {
  for_each = var.resource_buckets

  bucket        = each.value.bucket_name
  force_destroy = true

  tags = {
    Name        = each.value.bucket_title_name
    Environment = var.environment
    Group       = var.resource_group
    Vendor      = "Self"
    Type        = "Self Made"
  }
}

resource "aws_s3_bucket_ownership_controls" "bucket" {
  for_each = var.resource_buckets
  bucket   = aws_s3_bucket.bucket[each.key].id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "bucket" {
  for_each = var.resource_buckets
  bucket   = aws_s3_bucket.bucket[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload Buckets
module "aws_s3_upload_bucket" {
  source   = "./modules/aws-s3-upload-bucket"
  for_each = var.upload_buckets

  name           = each.key
  resource_group = var.resource_group
  environment    = var.environment

  bucket_cors_allowed_origins = try(each.value.bucket_cors_allowed_origins)

  tags = try(each.value.tags)
}

module "aws_s3_upload_bucket_cloudfront_cdn" {
  source = "./modules/aws-s3-upload-bucket"

  for_each = var.upload_buckets

  name           = each.key
  resource_group = var.resource_group
  environment    = var.environment

  enable_cdn                 = try(each.value.enable_cdn, null)
  cdn_subdomain              = try(each.value.cdn_subdomain, null)
  cdn_domain                 = try(each.value.cdn_domain)
  cdn_zone_id                = try(each.value.cdn_zone_id)
  cdn_public_key_secret_name = try(each.value.cdn_public_key_secret_name)

  tags = try(each.value.tags)
}
