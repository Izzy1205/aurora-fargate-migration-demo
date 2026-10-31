# Own execution and task roles, under the vault boundary from bootstrap.
# Bootstrap only lets the terraform role create ${name_prefix}-ssn-vault-*
# roles with that boundary, and lets the deploy role pass exactly these two.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${local.name}-execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

# Pull the app image and write its own logs. No secrets to inject.
data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource scoping
  }

  statement {
    sid = "PullAppRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.repository_arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.vault.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

resource "aws_iam_role" "task" {
  name                 = "${local.name}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

# Same policy the app task role has today. A later PR removes it from the
# app.
resource "aws_iam_role_policy" "task" {
  name   = "ssn-vault"
  role   = aws_iam_role.task.id
  policy = var.task_policy_json
}
