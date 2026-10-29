data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  part    = data.aws_partition.current.partition
  region  = var.aws_region
  p       = var.name_prefix

  oidc_host = "token.actions.githubusercontent.com"
  oidc_arn  = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # Must match names in the main stack. Built here so there's no state dependency.
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

  rds_secrets   = "arn:${local.part}:secretsmanager:*:${local.account}:secret:rds!*"
  login_secrets = "arn:${local.part}:secretsmanager:*:${local.account}:secret:${local.p}/db/*"
  ci_roles      = "arn:${local.part}:iam::${local.account}:role/${local.p}-github-*"

  # Must carry the workload boundary.
  stack_roles = "arn:${local.part}:iam::${local.account}:role/${local.p}-*"

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

# Trust is based on the GitHub "sub" claim. Both classic and immutable repo forms are accepted.
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

# No CI role can read DB credentials. Login secrets are write-only so TF never reads them.
data "aws_iam_policy_document" "deny_db_secret" {
  statement {
    sid       = "NoDbCredentials"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.rds_secrets, local.login_secrets]
  }
}
