resource "aws_s3_bucket" "bucket" {
  for_each      = var.resource_buckets

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

resource "aws_s3_bucket_acl" "bucket_acl" {
  for_each      = var.resource_buckets

  bucket = aws_s3_bucket.bucket[each.key].id
  acl    = "private"
}
