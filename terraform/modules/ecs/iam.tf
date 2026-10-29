# Each task gets its own roles, and only db-logins can read the master secret.

locals {
  task_kinds = {
    app = {
      repository_arn = var.app_repository_arn
      log_group_arn  = aws_cloudwatch_log_group.app.arn
      secret_arns    = [var.app_secret_arn]
    }
    migrate = {
      repository_arn = var.migration_repository_arn
      log_group_arn  = aws_cloudwatch_log_group.migration.arn
      secret_arns    = [var.migrator_secret_arn]
    }
    db-logins = {
      repository_arn = var.migration_repository_arn
      log_group_arn  = aws_cloudwatch_log_group.migration.arn
      secret_arns    = [var.master_secret_arn, var.app_secret_arn, var.migrator_secret_arn]
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

  name                 = "${var.name_prefix}-${each.key}-execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "execution" {
  for_each = local.task_kinds

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action doesn't support resource scoping
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
    resources = each.value.secret_arns
  }
}

resource "aws_iam_role_policy" "execution" {
  for_each = local.task_kinds

  name   = "execution"
  role   = aws_iam_role.execution[each.key].id
  policy = data.aws_iam_policy_document.execution[each.key].json
}

# No permissions. They exist so PassRole can be scoped to them.
resource "aws_iam_role" "task" {
  for_each = local.task_kinds

  name                 = "${var.name_prefix}-${each.key}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = var.permissions_boundary_arn
}
