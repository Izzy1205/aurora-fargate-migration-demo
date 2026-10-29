# Caps every role the main stack creates. Anything not here, including IAM, is out of reach.
# Growing it needs a bootstrap re-apply.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action doesn't support resource scoping
  }

  statement {
    sid = "PullProjectImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:${local.part}:ecr:${local.region}:${local.account}:repository/${local.p}/*"]
  }

  statement {
    sid     = "WriteProjectLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [
      "arn:${local.part}:logs:${local.region}:${local.account}:log-group:/ecs/${local.p}/*",
      "arn:${local.part}:logs:${local.region}:${local.account}:log-group:/${local.p}/*",
    ]
  }

  # Each role's own policy narrows this to one secret.
  statement {
    sid     = "ReadDbSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:${local.part}:secretsmanager:${local.region}:${local.account}:secret:rds!*",
      "arn:${local.part}:secretsmanager:${local.region}:${local.account}:secret:${local.p}/db/*",
    ]
  }

  statement {
    sid       = "DecryptSecretViaSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }

  # ChangeMessageVisibility is here so the app team won't need a bootstrap change later.
  statement {
    sid = "UseProjectQueues"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = ["arn:${local.part}:sqs:${local.region}:${local.account}:${local.p}-*"]
  }

  # Key ARN doesn't exist yet at bootstrap time, so scope by the SQS caller instead.
  statement {
    sid       = "UseQueueKeyViaSqs"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sqs.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "${local.p}-workload-boundary"
  description = "Permissions boundary for roles the main stack creates."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}
