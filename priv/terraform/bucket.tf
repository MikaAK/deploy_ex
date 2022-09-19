### Release Bucket ###
######################
resource "aws_s3_bucket" "release_bucket" {
  bucket        = var.release_bucket_name
  force_destroy = true

  tags = {
    Name        = var.release_bucket_title_name
    Environment = var.environment
    Group       = var.resource_group
  }
}

resource "aws_s3_bucket_acl" "release_bucket_acl" {
  bucket = aws_s3_bucket.release_bucket.id
  acl    = "private"
}

### Logging Bucket ###
######################
resource "aws_s3_bucket" "logging_bucket" {
  bucket        = var.logging_bucket_name
  force_destroy = true

  tags = {
    Name        = var.logging_bucket_title_name
    Environment = var.environment
    Group       = var.resource_group
  }
}

resource "aws_s3_bucket_acl" "logging_bucket_acl" {
  bucket = aws_s3_bucket.logging_bucket.id
  acl    = "private"
}
