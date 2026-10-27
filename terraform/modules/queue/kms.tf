# Both queues are encrypted with this customer managed key. A CMK, not the
# AWS managed alias/aws/sqs key, so access is spelled out in IAM and the key
# can be shared with a producer in another role later.
#
# Cost: $1 a month prorated by the hour. SQS caches the data key
# (kms_data_key_reuse_period_seconds), so KMS request charges stay tiny.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "queue" {
  description             = "${var.name_prefix} payment queues"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.queue_key.json
}

resource "aws_kms_alias" "queue" {
  name          = "alias/${var.name_prefix}-payments"
  target_key_id = aws_kms_key.queue.key_id
}

data "aws_iam_policy_document" "queue_key" {
  # Same reasoning as the alarm key in modules/observability: in a key
  # policy "*" is this key only.
  #checkov:skip=CKV_AWS_109:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_111:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_356:Key policy, "*" is this key only

  # Access goes through IAM. The task role gets its KMS actions from the
  # policy in layers/app, limited to calls made by SQS.
  statement {
    sid       = "AccountAccessThroughIam"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}
