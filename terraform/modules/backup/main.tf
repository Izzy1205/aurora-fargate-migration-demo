# Daily Aurora backups with a copy in a second region, so the data
# survives losing the home region (us-east-2 in testing).
#
# Why AWS Backup and not something else:
#   - Aurora has no cross-Region automated backup replication. That RDS
#     feature (aws_db_instance_automated_backups_replication) is for RDS
#     instances only. The Aurora guide says so under "Retaining automated
#     backups".
#   - Aurora Global Database would keep a live replica in the second
#     region. That is the answer for a low RTO, but it means a second
#     cluster running all the time, which is far past what this demo needs.
#   - AWS Backup takes a cluster snapshot on a schedule and copies it to a
#     vault in another region in the same plan rule. Aurora supports
#     cross-Region copy (AWS Backup "Feature availability by resource").
#     One plan, one selection, two vaults, one key.
#
# Snapshot backups, not continuous ones. A continuous (point in time)
# backup becomes a plain snapshot when it is copied to another region
# anyway, and the cluster already has in-region point in time restore
# from its own automated backups.
#
# What this does NOT do: it is not active-active and nothing fails over.
# Restoring is manual: pick a recovery point in the DR vault and restore
# it to a new cluster there, then point a stack at it.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_region" "dr" {
  provider = aws.dr
}

# Created by bootstrap (modules/github_oidc/backup.tf). Looked up by name
# so a plan fails right away if bootstrap hasn't been applied yet.
data "aws_iam_role" "backup" {
  name = var.backup_role_name
}

locals {
  account = data.aws_caller_identity.current.account_id
  part    = data.aws_partition.current.partition
}

# Home region vault. Aurora isn't fully managed by AWS Backup, so its
# snapshots keep the cluster's own key (aws/rds here) and this vault's key
# is never used for them. AWS Backup encrypts the vault itself with its
# AWS managed key, which costs nothing.
#
# force_destroy deletes the recovery points on destroy, so teardown
# removes the snapshots too instead of failing on a non-empty vault.
resource "aws_backup_vault" "home" {
  #checkov:skip=CKV_AWS_166:Aurora snapshots keep the cluster key, the vault key is never used for them
  name          = "${var.name_prefix}-aurora"
  force_destroy = true
}

# DR region vault. A cross-Region copy of an Aurora snapshot is encrypted
# with the destination vault's key, and for Aurora that key must be a
# customer managed key or the RDS managed key in that region. The AWS
# Backup managed key isn't allowed (AWS Backup "Encryption for backups").
# aws/rds only exists in a region once RDS has been used there, so this
# makes its own key.
resource "aws_backup_vault" "dr" {
  provider = aws.dr

  name          = "${var.name_prefix}-aurora-dr"
  kms_key_arn   = aws_kms_key.dr.arn
  force_destroy = true
}

# Cost: $1 a month prorated by the hour, nothing once destroy has
# scheduled it for deletion. The 7 day wait doesn't hold up teardown.
resource "aws_kms_key" "dr" {
  provider = aws.dr

  description             = "${var.name_prefix} Aurora backup copies"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.dr_key.json
}

resource "aws_kms_alias" "dr" {
  provider = aws.dr

  name          = "alias/${var.name_prefix}-backup-dr"
  target_key_id = aws_kms_key.dr.key_id
}

data "aws_iam_policy_document" "dr_key" {
  # Same reasoning as the alarm topic key: in a key policy "*" can only
  # mean this key, and the root statement is the default AWS puts on
  # every key so IAM policies decide access.
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

  # The backup role gets the key through IAM as well (its managed policy
  # allows DescribeKey and CreateGrant). This says it again on the key so
  # the copy doesn't depend on that policy staying the same. The grant
  # condition is the one from the AWS Backup encryption guide: grants only
  # for AWS resources, which is how RDS uses the key during the copy.
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
    rule_name         = "daily-with-dr-copy"
    target_vault_name = aws_backup_vault.home.name
    schedule          = var.schedule

    # Start within an hour of the schedule or skip the day. A snapshot of
    # this cluster takes minutes, so 8 hours to finish is plenty.
    start_window      = 60
    completion_window = 480

    lifecycle {
      delete_after = var.retention_days
    }

    # The copy starts when the backup finishes. Aurora copies are always
    # full copies in the destination, can take hours for big clusters, and
    # count toward a limit of 5 cross-Region snapshot copies in flight per
    # destination region.
    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        delete_after = var.dr_retention_days
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
