# Plan role, used by pull requests. Read only.
resource "aws_iam_role" "plan" {
  name                 = "${local.p}-github-plan"
  description          = "terraform plan from pull requests. Read only."
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.part}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan" {
  source_policy_documents = [data.aws_iam_policy_document.deny_db_secret.json]

  statement {
    sid       = "StateRead"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.part}:s3:::${var.state_bucket_name}"]
  }

  statement {
    sid       = "StateObjectRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.part}:s3:::${var.state_bucket_name}/${var.state_key}"]
  }

  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:${local.part}:s3:::${var.state_bucket_name}/${var.state_key}.tflock"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "state-and-guardrails"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# Apply role, used by the infra job in the production-infra environment.
# Can't read DB credentials or edit the CI roles or the OIDC provider.
resource "aws_iam_role" "apply" {
  name                 = "${local.p}-github-terraform"
  description          = "terraform apply on main. Owns infrastructure, never schema or credentials."
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
  max_session_duration = 3600
}

# PowerUserAccess covers every non-IAM service the stack uses. Too broad for
# real use; I'd replace it with a policy generated from CloudTrail by IAM
# Access Analyzer.
resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.part}:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply" {
  source_policy_documents = [data.aws_iam_policy_document.deny_db_secret.json]

  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole",
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:${local.part}:iam::${local.account}:role/${local.p}-*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.part}:iam::${local.account}:role/aws-service-role/*"]
  }

  statement {
    sid       = "NoTouchingCiIdentity"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = [local.ci_roles, local.oidc_arn]
  }

  statement {
    sid       = "NoRunningTasks"
    effect    = "Deny"
    actions   = ["ecs:RunTask", "ecs:StartTask", "ecs:ExecuteCommand"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "scoped-iam-and-guardrails"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}

# Deploy role, used by the release job in the production-app environment.
# Pushes images, runs the Flyway task, rolls the service. Can't change
# infrastructure or read the secret.
resource "aws_iam_role" "deploy" {
  name                 = "${local.p}-github-deploy"
  description          = "Push images, run Flyway task, update ECS service. No infrastructure changes."
  assume_role_policy   = data.aws_iam_policy_document.trust["deploy"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  source_policy_documents = [data.aws_iam_policy_document.deny_db_secret.json]

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
    ]
    resources = local.ecr_repo_arns
  }

  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"] # these actions do not support resource scoping
  }

  statement {
    sid       = "RunMigrationTaskOnly"
    actions   = ["ecs:RunTask"]
    resources = [local.migration_taskdef]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.cluster_arn]
    }
  }

  statement {
    sid       = "WatchTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = [local.cluster_tasks]
  }

  statement {
    sid       = "RollService"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [local.service_arn]
  }

  statement {
    sid       = "PassOnlyTaskRoles"
    actions   = ["iam:PassRole"]
    resources = local.passable_roles
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadMigrationLogs"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = [local.migration_log_group]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-and-migrate"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
