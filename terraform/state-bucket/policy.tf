resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.bucket.json

  # Block Public Access has to be in place before a policy is attached.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

locals {
  bucket_arn = "arn:${local.partition}:s3:::${var.bucket_name}"

  # Every way a request can name the state key: key ARN, key id, alias
  # name and alias ARN.
  state_key_ids = var.use_kms ? [
    aws_kms_key.state[0].arn,
    aws_kms_key.state[0].key_id,
    aws_kms_alias.state[0].name,
    "arn:${local.partition}:kms:${var.aws_region}:${local.account_id}:${aws_kms_alias.state[0].name}",
  ] : []
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
  # AES256 on state and lock writes and this would block them. Only fires
  # when the request has an encryption header. A Deny with
  # StringNotEqualsIfExists still denies when the key is missing, so the
  # Null check is what lets uploads with no header through. Those get the
  # bucket default key, which is how tg-plan.yml uploads saved plans.
  # UploadPart has no header either.
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html#Conditions_IfExists
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
        test     = "StringNotEquals"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["aws:kms"]
      }

      condition {
        test     = "Null"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["false"]
      }
    }
  }

  # Off by default. Denies a PutObject (and CopyObject into the bucket)
  # that names a KMS key other than this bucket's. No key id header means
  # the bucket default key, so the Null check lets that through, same as
  # above. Lock files go through this too: the backend sends the same
  # kms_key_id on the .tflock.
  #
  # The backends send the alias (root.hcl, bootstrap.sh) and
  # reencrypt-state.sh sends the key ARN. AWS says to write this condition
  # with the key ARN but doesn't say whether S3 resolves an alias before it
  # checks, so every form of this key is listed. The alias can only point
  # here as long as CI can't move it (DenyCiKeyAdmin in kms.tf).
  # https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html#require-sse-kms
  dynamic "statement" {
    for_each = var.use_kms && var.deny_wrong_kms_key ? [1] : []

    content {
      sid       = "DenyWrongKmsKey"
      effect    = "Deny"
      actions   = ["s3:PutObject"]
      resources = ["${local.bucket_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEquals"
        variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
        values   = local.state_key_ids
      }

      condition {
        test     = "Null"
        variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
        values   = ["false"]
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
