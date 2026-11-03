# Customer managed key for the bucket's default encryption. Only used when
# use_kms is true.
#
# Terraform's S3 backend sends its own SSE header (AES256) unless the
# backend sets kms_key_id. root.hcl and scripts/bootstrap.sh set it to this
# key's alias, so state and lock files get this key. Objects written
# without a header, such as the saved plans from tg-plan.yml, get it from
# the bucket default. State written before that change stays SSE-S3 until
# it's written again or scripts/reencrypt-state.sh copies it.

resource "aws_kms_key" "state" {
  count = var.use_kms ? 1 : 0

  description             = "${var.project} Terraform state bucket ${var.bucket_name}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days
  policy                  = data.aws_iam_policy_document.kms[0].json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  count = var.use_kms ? 1 : 0

  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

# In a key policy, "*" as the resource means this key only.
# https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-overview.html
data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_356:Key policy. Resource "*" is this key only.
  #checkov:skip=CKV_AWS_111:Key policy. Resource "*" is this key only, and CI use is limited by conditions.
  #checkov:skip=CKV_AWS_109:Key policy. Resource "*" is this key only, and CI key admin is denied.
  count = var.use_kms ? 1 : 0

  # Lets IAM policies in this account grant use of the key. Without it the
  # key can become unmanageable.
  statement {
    sid       = "EnableIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # The plan role only has ReadOnlyAccess, which has no kms:Decrypt or
  # GenerateDataKey. Grant just those to the CI roles, only through S3 and
  # only for this bucket. That's all SSE-KMS needs: GenerateDataKey to
  # write, Decrypt to read. kms:Encrypt is never called. See
  # https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html
  # Same account, so this grant works without an IAM allow. The roles'
  # IAM policies deny the key outside S3 (NoStateKeyOutsideS3).
  statement {
    sid       = "CiRolesUseThroughS3"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [local.ci_role_arn_pattern]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values = [
        "arn:${local.partition}:s3:::${var.bucket_name}",
        "arn:${local.partition}:s3:::${var.bucket_name}/*",
      ]
    }
  }

  # The apply role has PowerUserAccess, which includes KMS admin actions.
  statement {
    sid    = "DenyCiKeyAdmin"
    effect = "Deny"
    actions = [
      "kms:CancelKeyDeletion",
      "kms:CreateGrant",
      "kms:DisableKey",
      "kms:DisableKeyRotation",
      "kms:PutKeyPolicy",
      "kms:RevokeGrant",
      "kms:ScheduleKeyDeletion",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:UpdateKeyDescription",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [local.ci_role_arn_pattern]
    }
  }
}
