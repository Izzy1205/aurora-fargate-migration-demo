# CMK so access is spelled out in IAM. SQS caches the data key, so KMS costs stay tiny.

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
  # Key policy: "*" is this key only.
  #checkov:skip=CKV_AWS_109:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_111:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_356:Key policy, "*" is this key only

  # Task role gets KMS only through SQS (layers/app).
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
