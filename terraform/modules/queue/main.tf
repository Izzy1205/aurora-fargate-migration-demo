# Payment requests queue with a dead letter queue.
#
# This is the platform guardrail, not the payment logic. The app team writes
# the consumer and owns idempotency: every message carries an idempotency
# key, and the consumer must treat a repeat of that key as already done.
# SQS standard queues deliver at least once, so repeats will happen.
#
# A message that fails max_receive_count times moves to the DLQ and an alarm
# fires (modules/observability). Nothing is retried from the DLQ
# automatically; someone looks at it, then redrives it from the console.

locals {
  name = "${var.name_prefix}-payment-requests"
}

resource "aws_sqs_queue" "dlq" {
  name                              = "${local.name}-dlq"
  message_retention_seconds         = 1209600 # 14 days, the SQS maximum
  kms_master_key_id                 = aws_kms_key.queue.arn
  kms_data_key_reuse_period_seconds = 300
}

resource "aws_sqs_queue" "main" {
  name                              = local.name
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  message_retention_seconds         = var.message_retention_seconds
  receive_wait_time_seconds         = 20 # long polling, fewer empty receives
  kms_master_key_id                 = aws_kms_key.queue.arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Only the main queue may use the DLQ as its dead letter target.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

# Refuse anything not sent over TLS. The endpoint is HTTPS anyway; this
# makes it a rule instead of a habit.
resource "aws_sqs_queue_policy" "tls_only" {
  for_each = {
    main = aws_sqs_queue.main
    dlq  = aws_sqs_queue.dlq
  }

  queue_url = each.value.id
  policy    = data.aws_iam_policy_document.tls_only[each.key].json
}

data "aws_iam_policy_document" "tls_only" {
  for_each = {
    main = aws_sqs_queue.main.arn
    dlq  = aws_sqs_queue.dlq.arn
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value]
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
}

# What the app task needs: send, receive, delete and read attributes on the
# main queue, and use the key only through SQS. Nothing on the DLQ; people
# handle that. layers/app attaches it to the app task role.
data "aws_iam_policy_document" "task" {
  statement {
    sid = "PaymentQueue"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.main.arn]
  }

  statement {
    sid       = "PaymentQueueKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.queue.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sqs.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}
