# Two execution roles (used by the ECS agent to pull the image, write logs and
# inject secrets) and two task roles (used by the running code). The app and
# migration each get their own pair, so the app cannot pull the Flyway image
# and the other way round.

locals {
  task_kinds = {
    app = {
      repository_arn = var.app_repository_arn
      log_group_arn  = aws_cloudwatch_log_group.app.arn
    }
    migrate = {
      repository_arn = var.migration_repository_arn
      log_group_arn  = aws_cloudwatch_log_group.migration.arn
    }
  }
}

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
  for_each = local.task_kinds

  name               = "${var.name_prefix}-${each.key}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  for_each = local.task_kinds

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource scoping
  }

  statement {
    sid = "PullOwnRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [each.value.repository_arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${each.value.log_group_arn}:*"]
  }

  statement {
    sid       = "ReadDbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  for_each = local.task_kinds

  name   = "execution"
  role   = aws_iam_role.execution[each.key].id
  policy = data.aws_iam_policy_document.execution[each.key].json
}

# Task roles carry no permissions. Neither container calls AWS APIs; they only
# talk to Postgres. The roles exist so the deploy role's PassRole can be
# scoped to them.
resource "aws_iam_role" "task" {
  for_each = local.task_kinds

  name               = "${var.name_prefix}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}
