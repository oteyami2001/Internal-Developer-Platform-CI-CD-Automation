# CloudTrail (owner decision 2026-11-23): the account had no trail, only the 90-day Event history.
# A single-Region trail of management events (read + write) gives durable evidence of who did
# what: every AssumeRoleWithWebIdentity (with the GitHub OIDC subject), every Terraform API call.
# Cost: the first copy of management events is free; only S3 storage (cents/month) is billed.

#trivy:ignore:AVD-AWS-0089 Access logging of the audit bucket would need a third bucket; the trail records its management API calls.
resource "aws_s3_bucket" "trail" {
  # checkov:skip=CKV_AWS_144:Cross-Region replication: the other US Region is SCP-denied; versioning protects history.
  # checkov:skip=CKV_AWS_18:Access logging of the audit bucket would need a third bucket; the trail records its management API calls.
  # checkov:skip=CKV2_AWS_62:Event notifications are not needed for an audit bucket.
  # checkov:skip=CKV_AWS_145:SSE-S3: CloudTrail cannot write with the AWS managed aws/s3 KMS key, and a customer managed key adds $1/month.
  bucket = local.trail_bucket

  lifecycle {
    prevent_destroy = true # audit evidence
  }
}

resource "aws_s3_bucket_ownership_controls" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id
  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AVD-AWS-0132 SSE-S3: CloudTrail cannot deliver to a bucket encrypted with the AWS managed aws/s3 key; a CMK costs $1/month.
resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "retention"
    status = "Enabled"
    filter {}
    expiration {
      days = var.cloudtrail_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

locals {
  trail_arn = "arn:aws:cloudtrail:${var.region}:${var.aws_account_id}:trail/${local.trail_name}"
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail.arn
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/${var.aws_account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.trail_arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        # Log files are evidence: nobody deletes them early (the lifecycle rule expires them).
        Sid       = "DenyLogDeletion"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/*"
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

#trivy:ignore:AVD-AWS-0014 Single-Region trail by owner decision; the other US Region is SCP-denied for regional services.
#trivy:ignore:AVD-AWS-0015 No customer managed KMS key ($1/month); SSE-S3 at rest plus log file validation.
#trivy:ignore:AVD-AWS-0162 No CloudWatch Logs delivery: ingestion cost; S3 + Event history are queried instead.
resource "aws_cloudtrail" "management" {
  # checkov:skip=CKV_AWS_67:Single-Region trail by owner decision (2026-11-23); us-east-1 is SCP-denied for regional services.
  # checkov:skip=CKV_AWS_35:No customer managed KMS key ($1/month); SSE-S3 at rest plus log file validation.
  # checkov:skip=CKV_AWS_252:No SNS topic per log delivery; not needed for this use.
  # checkov:skip=CKV2_AWS_10:No CloudWatch Logs integration: ingestion cost; S3 + Event history are queried instead.
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = false
  include_global_service_events = true # IAM and STS events
  enable_log_file_validation    = true # tamper-evident digest files
  enable_logging                = true

  depends_on = [aws_s3_bucket_policy.trail]
}
