# Role AWS Backup runs as. Lives here since the workload boundary blocks snapshot/copy rights.
# /service-role/ path keeps it out of stack_roles, so CI can only GetRole and PassRole it.
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

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.part}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
