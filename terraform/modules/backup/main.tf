# Daily Aurora snapshots, with an optional copy to the DR region.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_region" "dr" {
  provider = aws.dr
}

# Made by bootstrap. Lookup fails the plan fast if bootstrap wasn't applied.
data "aws_iam_role" "backup" {
  name = var.backup_role_name
}

locals {
  account = data.aws_caller_identity.current.account_id
  part    = data.aws_partition.current.partition
}

# Aurora snapshots keep the cluster key, so this vault's key is never used.
# force_destroy so teardown doesn't fail on a non-empty vault.
resource "aws_backup_vault" "home" {
  #checkov:skip=CKV_AWS_166:Aurora snapshots keep the cluster key, the vault key is never used for them
  name          = "${var.name_prefix}-aurora"
  force_destroy = true
}

# Aurora copies can't use the AWS Backup managed key, and aws/rds may not exist
# in the DR region yet, so it gets its own key.
resource "aws_backup_vault" "dr" {
  count    = var.dr_copy_enabled ? 1 : 0
  provider = aws.dr

  name          = "${var.name_prefix}-aurora-dr"
  kms_key_arn   = aws_kms_key.dr[0].arn
  force_destroy = true
}

resource "aws_kms_key" "dr" {
  count    = var.dr_copy_enabled ? 1 : 0
  provider = aws.dr

  description             = "${var.name_prefix} Aurora backup copies"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.dr_key.json
}

resource "aws_kms_alias" "dr" {
  count    = var.dr_copy_enabled ? 1 : 0
  provider = aws.dr

  name          = "alias/${var.name_prefix}-backup-dr"
  target_key_id = aws_kms_key.dr[0].key_id
}

data "aws_iam_policy_document" "dr_key" {
  # Key policy: "*" is this key only.
  #checkov:skip=CKV_AWS_109:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_111:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_356:Key policy, "*" is this key only

  statement {
    sid       = "AccountAccessThroughIam"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.part}:iam::${local.account}:root"]
    }
  }

  # Grant only for AWS resources, which is how RDS uses the key during the copy.
  statement {
    sid       = "BackupRoleDescribe"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.backup.arn]
    }
  }

  statement {
    sid       = "BackupRoleGrants"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.backup.arn]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    sid = "BackupRoleUseThroughServices"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.backup.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "rds.${data.aws_region.dr.region}.amazonaws.com",
        "backup.${data.aws_region.dr.region}.amazonaws.com",
      ]
    }
  }
}

resource "aws_backup_plan" "this" {
  name = "${var.name_prefix}-aurora"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.home.name
    schedule          = var.schedule

    start_window      = 60
    completion_window = 480

    lifecycle {
      delete_after = var.retention_days
    }

    dynamic "copy_action" {
      for_each = aws_backup_vault.dr
      content {
        destination_vault_arn = copy_action.value.arn

        lifecycle {
          delete_after = var.dr_retention_days
        }
      }
    }
  }
}

resource "aws_backup_selection" "aurora" {
  name         = "${var.name_prefix}-aurora"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = data.aws_iam_role.backup.arn
  resources    = [var.cluster_arn]
}
