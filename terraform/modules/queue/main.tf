# Platform side only. SQS delivers at least once, so the consumer must be idempotent.
# DLQ messages aren't redriven automatically.

locals {
  name = "${var.name_prefix}-payment-requests"
}

resource "aws_sqs_queue" "dlq" {
  name                              = "${local.name}-dlq"
  message_retention_seconds         = 1209600 # 14 days, the max
  kms_master_key_id                 = aws_kms_key.queue.arn
  kms_data_key_reuse_period_seconds = 300
}

resource "aws_sqs_queue" "main" {
  name                              = local.name
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  message_retention_seconds         = var.message_retention_seconds
  receive_wait_time_seconds         = 20 # long polling
  kms_master_key_id                 = aws_kms_key.queue.arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

# Reject anything not over TLS.
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

# Send, receive, delete on the main queue. Nothing on the DLQ.
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
