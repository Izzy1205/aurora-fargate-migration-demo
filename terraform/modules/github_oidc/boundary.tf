# Permissions boundary for every role the main stack creates. A role's
# effective permissions are its own policies AND this boundary, so even if the
# terraform role puts AdministratorAccess on a new role, the role still can't
# do more than what's listed here. Anything not listed is out of reach,
# including all of IAM.
#
# This covers what the ECS execution roles, the flow logs role and the app
# task role (payment queue) actually use. The migrate task role has no
# policies. If the main stack ever needs a role that does more, the boundary
# has to grow here first, by hand, and bootstrap has to be applied again.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource scoping
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

  # The execution roles inject the DB credentials at task start.
  statement {
    sid       = "ReadRdsManagedSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.part}:secretsmanager:${local.region}:${local.account}:secret:rds!*"]
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

  # The app task sends and consumes payment requests. Project queues only.
  # ChangeMessageVisibility is allowed here so the app team can extend a
  # message's timeout later without another bootstrap change; the task role
  # itself doesn't grant it yet.
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

  # The queues are encrypted with a project key. The key ARN doesn't exist
  # yet when bootstrap runs, so this is limited to calls SQS makes instead.
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
