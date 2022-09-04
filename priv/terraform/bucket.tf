resource "aws_s3_bucket" "release_bucket" {
  bucket = var.release_bucket_name

  tags = {
    Name        = var.release_bucket_title_name
    Environment = var.environment
    Group       = var.instance_group
  }
}

resource "aws_s3_bucket_acl" "release_bucket_acl" {
  bucket = aws_s3_bucket.release_bucket.id
  acl    = "private"
}

