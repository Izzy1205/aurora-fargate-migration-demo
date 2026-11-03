# Remote state bucket for every root in this repo. Applied by hand with
# admin creds through scripts/bootstrap.sh state-bucket, never from CI.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Owner     = var.owner
      ManagedBy = "terraform-state-bucket"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Role names come from modules/github_oidc: <project>-<env>-github-<role>.
  ci_role_arn_pattern = "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-*-github-*"
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:Access logs need a second bucket. CloudTrail covers bucket API calls.
  #checkov:skip=CKV2_AWS_62:Nothing consumes events from a state bucket.
  #checkov:skip=CKV_AWS_144:Single-region demo. Versioning covers lost or bad state.
  bucket = var.bucket_name

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.expected_account_id == null || local.account_id == var.expected_account_id
      error_message = "The AWS credentials are not for expected_account_id. Sign in to the right account."
    }
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.use_kms ? "aws:kms" : "AES256"
      kms_master_key_id = var.use_kms ? aws_kms_key.state[0].arn : null
    }
    bucket_key_enabled       = var.use_kms
    blocked_encryption_types = ["SSE-C"]
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_version_days
      newer_noncurrent_versions = var.noncurrent_versions_to_keep
    }

    # Lock files leave a delete marker on every run. Clear the marker once
    # its old versions have expired.
    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_multipart_days
    }
  }

  # Lifecycle rules need versioning in place first.
  depends_on = [aws_s3_bucket_versioning.state]
}
