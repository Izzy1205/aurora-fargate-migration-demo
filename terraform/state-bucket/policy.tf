resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.bucket.json

  # Block Public Access has to be in place before a policy is attached.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

locals {
  bucket_arn = "arn:${local.partition}:s3:::${var.bucket_name}"
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = var.require_tls_1_2 ? [1] : []

    content {
      sid       = "DenyTlsOlderThan12"
      effect    = "Deny"
      actions   = ["s3:*"]
      resources = [local.bucket_arn, "${local.bucket_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "NumericLessThan"
        variable = "s3:TlsVersion"
        values   = ["1.2"]
      }
    }
  }

  # Off by default. Until every backend sets kms_key_id, Terraform sends
  # AES256 on state and lock writes and this would block them. Uploads
  # with no header still go through and get the bucket default key, which
  # is how tg-plan.yml uploads saved plans. UploadPart has no header either.
  dynamic "statement" {
    for_each = var.use_kms && var.deny_non_kms_uploads ? [1] : []

    content {
      sid       = "DenyNonKmsUploads"
      effect    = "Deny"
      actions   = ["s3:PutObject"]
      resources = ["${local.bucket_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEqualsIfExists"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["aws:kms"]
      }
    }
  }

  # CI reads and writes state and plans but never changes the bucket
  # (root.hcl sets disable_bucket_update). Plain DeleteObject stays allowed
  # because the backend removes its lock file that way.
  dynamic "statement" {
    for_each = var.deny_ci_bucket_admin ? [1] : []

    content {
      sid    = "DenyCiBucketAdmin"
      effect = "Deny"
      actions = [
        "s3:DeleteBucket",
        "s3:DeleteBucketPolicy",
        "s3:DeleteObjectVersion",
        "s3:PutBucketAcl",
        "s3:PutBucketObjectLockConfiguration",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketPolicy",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketTagging",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:PutReplicationConfiguration",
      ]
      resources = [local.bucket_arn, "${local.bucket_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:PrincipalArn"
        values   = [local.ci_role_arn_pattern]
      }
    }
  }
}
