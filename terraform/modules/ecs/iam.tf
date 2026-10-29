# The app, the migration and the db-logins task each get their own
# execution role (pull image, write logs, inject secrets) and task role. Each
# execution role can read only the DB secrets its own task needs: the app
# gets the app login, Flyway gets the Flyway login, and only db-logins can
# read the master secret.

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
    resources = each.value.secret_arns
  }
}

resource "aws_iam_role_policy" "execution" {
  for_each = local.task_kinds

  name   = "execution"
  role   = aws_iam_role.execution[each.key].id
  policy = data.aws_iam_policy_document.execution[each.key].json
}

# No permissions here. They exist so the deploy role's PassRole can be
# scoped to them. The app role gets its payment queue policy from
# layers/app; the migrate and db-logins roles have none.
resource "aws_iam_role" "task" {
  for_each = local.task_kinds

  name                 = "${var.name_prefix}-${each.key}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = var.permissions_boundary_arn
}
