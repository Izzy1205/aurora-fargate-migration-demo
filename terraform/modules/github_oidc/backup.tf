# The role AWS Backup runs as when it snapshots Aurora and copies the
# snapshot to the DR region (modules/backup in the main stack).
#
# Why it lives here and not in the main stack: the CI apply role can only
# create roles that carry the workload boundary, and that boundary is
# narrow on purpose. AWS Backup needs RDS snapshot, copy and KMS grant
# rights that the boundary doesn't allow, and widening the boundary would
# widen it for every role the stack makes. So bootstrap, which a person
# applies by hand, creates this one role and CI only gets to pass it to
# AWS Backup.
#
# The /service-role/ path keeps it out of local.stack_roles
# (role/<prefix>-*), so the CI apply role can't edit, re-trust or delete
# it. It only gets GetRole and PassRole, below in this file and in
# roles.tf.
resource "aws_iam_role" "backup" {
  name               = "${local.p}-backup"
  path               = "/service-role/"
  description        = "AWS Backup runs Aurora backups and cross-Region copies as this role."
  assume_role_policy = data.aws_iam_policy_document.backup_trust.json
}

data "aws_iam_policy_document" "backup_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

# The AWS managed policy AWS Backup's own default role uses. It covers
# rds:CreateDBClusterSnapshot, rds:CopyDBClusterSnapshot, deleting
# awsbackup:* snapshots when they expire, backup:CopyIntoBackupVault and
# kms:CreateGrant for AWS resources.
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.part}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
