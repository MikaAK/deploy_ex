locals {
  bucket_name = "${replace(var.name, "_", "-")}-uploads-${var.environment}"
}

module "aws_s3_upload_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"
  version = "4.0.1"

  bucket = local.bucket_name

  force_destroy = false
  acceleration_status = "Enabled"

  # Bucket policies
  attach_policy = true
  policy = <<EOF
  {
    "Version": "2008-10-17",
    "Id": "PolicyForCloudFrontPrivateContent",
    "Statement": [
      {
        "Sid": "AllowCloudFrontServicePrincipal",
        "Effect": "Allow",
        "Principal": {
          "Service": "cloudfront.amazonaws.com"
        },
        "Action": "s3:GetObject",
        "Resource": "arn:aws:s3:::${local.bucket_name}/*"
        ${var.enable_cdn ?
          ", \"Condition\": { \"StringEquals\": { \"AWS:SourceArn\": \"${module.aws_s3_upload_bucket_cloudfront_cdn[0].cloudfront_distribution_arn}\" } }"
          : ""
        }

      }
    ]
  }
  EOF



  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id = "abort_incomplete_multipart_uploads"
      enabled = true
      abort_incomplete_multipart_upload_days = 7
    },
    {
      id = "expire_temp"
      enabled = true

      filter = {
        prefix = "temp/"
      }

      expiration = {
        days = 31
      }
    }
  ]

  cors_rule = [
    {
      allowed_methods = ["GET", "PUT"]
      allowed_headers = ["Authorization", "x-amz-date", "x-amz-content-sha256", "content-type"]
      allowed_origins = var.bucket_cors_allowed_origins
      expose_headers  = ["ETag", "Location"]
      max_age_seconds = 3000
    }
  ]

  tags = merge({
   Name          = format("%s Bucket", replace(var.name, "_", " "))
   Group         = var.resource_group
   Environment   = var.environment
   Type          = "Self Made"
  }, var.tags)

}

