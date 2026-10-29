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
  cluster_arn = "arn:${local.part}:ecs:${local.region}:${local.account}:cluster/${local.p}-cluster"
  service_arn = "arn:${local.part}:ecs:${local.region}:${local.account}:service/${local.p}-cluster/${local.p}-app"
  runnable_taskdefs = [
    for f in ["migrate", "db-logins"] :
    "arn:${local.part}:ecs:${local.region}:${local.account}:task-definition/${local.p}-${f}:*"
  ]
  cluster_tasks       = "arn:${local.part}:ecs:${local.region}:${local.account}:task/${local.p}-cluster/*"
  ecr_repo_arns       = [for r in ["app", "migrate"] : "arn:${local.part}:ecr:${local.region}:${local.account}:repository/${local.p}/${r}"]
  migration_log_group = "arn:${local.part}:logs:${local.region}:${local.account}:log-group:/ecs/${local.p}/migrate:*"
  passable_roles = [
    for r in [
      "app-execution", "app-task",
      "migrate-execution", "migrate-task",
      "db-logins-execution", "db-logins-task",
    ] :
    "arn:${local.part}:iam::${local.account}:role/${local.p}-${r}"
  ]

  # RDS-managed secrets are always named rds!<resource>-<id>. The app and
  # Flyway logins live under <prefix>/db/ (see modules/database/logins.tf).
  rds_secrets   = "arn:${local.part}:secretsmanager:*:${local.account}:secret:rds!*"
  login_secrets = "arn:${local.part}:secretsmanager:*:${local.account}:secret:${local.p}/db/*"
  ci_roles      = "arn:${local.part}:iam::${local.account}:role/${local.p}-github-*"

  # Roles the main stack creates. Each must carry the workload boundary
  # (boundary.tf), which the main stack finds by name.
  stack_roles = "arn:${local.part}:iam::${local.account}:role/${local.p}-*"

  # Saved plans from deploy.yml, next to the state in the same bucket.
  plans_prefix = "arn:${local.part}:s3:::${var.state_bucket_name}/${var.plans_prefix}/*"
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

# Trust policy builder, based on the GitHub "sub" claim.
#   pull_request jobs           -> repo:OWNER/NAME:pull_request
#   jobs with environment: X    -> repo:OWNER/NAME:environment:X
# The plan role is also trusted from the plan environment, so the deploy
# workflow can make its saved plan without waiting on a reviewer.
#
# GitHub can send the repo part of "sub" in two forms: the classic
# repo:OWNER/NAME, or the immutable repo:OWNER@ID/NAME@ID form newer repos
# use. Both are accepted; extra prefixes come from var.github_subject_prefixes.
locals {
  subject_prefixes = distinct(concat(["repo:${var.github_repo}"], var.github_subject_prefixes))
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan   = ["pull_request", "environment:${var.plan_environment}"]
    apply  = ["environment:${var.infra_environment}"]
    deploy = ["environment:${var.app_environment}"]
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
      values   = flatten([for p in local.subject_prefixes : [for s in each.value : "${p}:${s}"]])
    }
  }
}

# Shared guardrail: no CI role can read the database credentials. Terraform
# still manages the login secrets, because their value is write-only: it is
# written once and refresh only lists the version IDs, it never reads it back.
data "aws_iam_policy_document" "deny_db_secret" {
  statement {
    sid       = "NoDbCredentials"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.rds_secrets, local.login_secrets]
  }
}
