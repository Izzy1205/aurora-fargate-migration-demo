data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  part    = data.aws_partition.current.partition
  region  = var.aws_region
  p       = var.name_prefix

  oidc_host = "token.actions.githubusercontent.com"
  oidc_arn  = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # These names must match what the main stack creates (see modules/ecs and
  # modules/registry). They are built here so this stack does not depend on
  # the main stack's state.
  cluster_arn         = "arn:${local.part}:ecs:${local.region}:${local.account}:cluster/${local.p}-cluster"
  service_arn         = "arn:${local.part}:ecs:${local.region}:${local.account}:service/${local.p}-cluster/${local.p}-app"
  migration_taskdef   = "arn:${local.part}:ecs:${local.region}:${local.account}:task-definition/${local.p}-migrate:*"
  cluster_tasks       = "arn:${local.part}:ecs:${local.region}:${local.account}:task/${local.p}-cluster/*"
  ecr_repo_arns       = [for r in ["app", "migrate"] : "arn:${local.part}:ecr:${local.region}:${local.account}:repository/${local.p}/${r}"]
  migration_log_group = "arn:${local.part}:logs:${local.region}:${local.account}:log-group:/ecs/${local.p}/migrate:*"
  passable_roles = [
    for r in ["app-execution", "app-task", "migrate-execution", "migrate-task"] :
    "arn:${local.part}:iam::${local.account}:role/${local.p}-${r}"
  ]

  # RDS-managed secrets are always named rds!<resource>-<id>.
  rds_secrets = "arn:${local.part}:secretsmanager:*:${local.account}:secret:rds!*"
  ci_roles    = "arn:${local.part}:iam::${local.account}:role/${local.p}-github-*"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://${local.oidc_host}"
}

# Trust policy builder: one role per GitHub "sub" claim.
#   pull_request jobs           -> repo:OWNER/NAME:pull_request
#   jobs with environment: X    -> repo:OWNER/NAME:environment:X
data "aws_iam_policy_document" "trust" {
  for_each = {
    plan   = "repo:${var.github_repo}:pull_request"
    apply  = "repo:${var.github_repo}:environment:${var.infra_environment}"
    deploy = "repo:${var.github_repo}:environment:${var.app_environment}"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [each.value]
    }
  }
}

# Shared guardrail: no CI role can read the database credentials.
data "aws_iam_policy_document" "deny_db_secret" {
  statement {
    sid       = "NoDbCredentials"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.rds_secrets]
  }
}
