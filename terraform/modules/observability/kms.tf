# The alarm topic is encrypted with its own customer managed key, not the AWS
# managed alias/aws/sns key. CloudWatch alarms can't publish to a topic that
# uses the AWS managed key: the alarm needs kms:GenerateDataKey and kms:Decrypt
# on the key, and the policy on an AWS managed key can't be changed to allow
# that. The alarm just fails with "CloudWatch Alarms does not have
# authorization to access the SNS topic encryption key".
#
# Cost: $1 a month prorated by the hour, and nothing once destroy has
# scheduled it for deletion. The 7 day deletion wait doesn't hold up
# teardown, Terraform schedules the deletion and moves on.
resource "aws_kms_key" "alarms" {
  description             = "${var.name_prefix} alarm topic"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.alarms_key.json
}

resource "aws_kms_alias" "alarms" {
  name          = "alias/${var.name_prefix}-alarms"
  target_key_id = aws_kms_key.alarms.key_id
}

data "aws_iam_policy_document" "alarms_key" {
  # These three checks are written for IAM policies. In a key policy,
  # "*" can only mean this key, and the root statement is the default AWS
  # puts on every key so IAM policies decide access.
  #checkov:skip=CKV_AWS_109:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_111:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_356:Key policy, "*" is this key only

  # Hands access to IAM, so the CI roles and admins work the way their IAM
  # policies say, and the key can't be locked out.
  statement {
    sid       = "AccountAccessThroughIam"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # What CloudWatch needs to publish to the encrypted topic. Only alarms in
  # this account can publish at all (see the topic policy in sns.tf).
  statement {
    sid       = "CloudWatchAlarmsUseKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}
