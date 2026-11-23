# Terraform remote state for every environment (envs/<env>/terraform.tfstate) and for this
# bootstrap itself (bootstrap/terraform.tfstate, after migration). Locking uses S3 native lock
# files (use_lockfile = true); no DynamoDB table.

#trivy:ignore:AVD-AWS-0089 Server access logging omitted for cost; the CloudTrail trail records bucket management API calls.
resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_144:Cross-Region replication: the only other US Region (us-east-1) is SCP-denied, and versioning already protects history.
  # checkov:skip=CKV_AWS_18:Server access logging omitted for cost; the CloudTrail trail records bucket management API calls.
  # checkov:skip=CKV2_AWS_62:Event notifications are not needed for a state bucket.
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true # losing state orphans every resource it tracks
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AVD-AWS-0132 SSE-KMS with the AWS managed aws/s3 key: encrypted at rest without a $1/month customer managed key; state holds no secret values.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms" # AWS managed aws/s3 key
    }
    bucket_key_enabled = true # fewer KMS requests
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10 # always keep the last 10 versions, however old
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOutdatedTls"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}
