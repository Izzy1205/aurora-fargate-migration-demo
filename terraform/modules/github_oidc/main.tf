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
  # The app service, and the SSN token service the app layer adds next.
  service_arns = [
    for s in ["app", "ssn-vault"] :
    "arn:${local.part}:ecs:${local.region}:${local.account}:service/${local.p}-cluster/${local.p}-${s}"
  ]
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
      "ssn-vault-execution", "ssn-vault-task",
    ] :
    "arn:${local.part}:iam::${local.account}:role/${local.p}-${r}"
  ]

  # RDS-managed secrets are always named rds!<resource>-<id>. The app and
  # Flyway logins live under <prefix>/db/ (see modules/database/logins.tf).
  rds_secrets   = "arn:${local.part}:secretsmanager:*:${local.account}:secret:rds!*"
  login_secrets = "arn:${local.part}:secretsmanager:*:${local.account}:secret:${local.p}/db/*"
  ssn_secrets   = "arn:${local.part}:secretsmanager:*:${local.account}:secret:${local.p}/ssn/*"
  ci_roles      = "arn:${local.part}:iam::${local.account}:role/${local.p}-github-*"

  # Roles the main stack creates. Each must carry the workload boundary
  # (boundary.tf), which the main stack finds by name.
  stack_roles = "arn:${local.part}:iam::${local.account}:role/${local.p}-*"

  # The SSN token service's roles. Only these may carry the vault boundary.
  vault_roles     = "arn:${local.part}:iam::${local.account}:role/${local.p}-ssn-vault-*"
  vault_log_group = "arn:${local.part}:logs:${local.region}:${local.account}:log-group:/ecs/${local.p}/ssn-vault"
  ssn_key_alias   = "alias/${local.p}-ssn"

  # Saved plans from deploy.yml, next to the state in the same bucket.
  # tg-plan.yml writes plans/<run>-<attempt>/<env>/<unit>/tfplan, so the
  # plan role can only write plans for its own environment.
  plans_prefix = "arn:${local.part}:s3:::${var.state_bucket_name}/${var.plans_prefix}/*/${var.environment}/*"

  # Promotion source (stage pulls from testing, production from stage).
  # Read only: the deploy role copies the scanned image by digest from the
  # source env's repos into its own, and checks the source service runs it.
  promote_from = var.promote_from_prefix
  promote_source_repo_arns = local.promote_from == "" ? [] : [
    for r in ["app", "migrate"] : "arn:${local.part}:ecr:${local.region}:${local.account}:repository/${local.promote_from}/${r}"
  ]
  promote_source_service_arns = local.promote_from == "" ? [] : [
    for s in ["app", "ssn-vault"] :
    "arn:${local.part}:ecs:${local.region}:${local.account}:service/${local.promote_from}-cluster/${local.promote_from}-${s}"
  ]
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
# Only testing trusts pull_request (var.trust_pull_request). That subject
# carries no environment, so any branch's PR could use a role that trusts it.
# Stage and production plan roles trust their plan environment only.
#
# GitHub can send the repo part of "sub" in two forms: the classic
# repo:OWNER/NAME, or the immutable repo:OWNER@ID/NAME@ID form newer repos
# use. Both are accepted; extra prefixes come from var.github_subject_prefixes.
locals {
  subject_prefixes = distinct(concat(["repo:${var.github_repo}"], var.github_subject_prefixes))
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan   = concat(var.trust_pull_request ? ["pull_request"] : [], ["environment:${var.plan_environment}"])
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

# Shared guardrail: all three environments share one account and one state
# bucket, and ReadOnlyAccess and PowerUserAccess both reach every S3 key. So
# no CI role can read or write another environment's state, or any
# bootstrap state. Each env's roles keep full use of their own prefix.
locals {
  state_key_root = trimsuffix(var.state_key_prefix, "/${var.environment}")
  peer_envs      = setsubtract(["testing", "stage", "production"], [var.environment])
  other_state = concat(
    [for e in sort(tolist(local.peer_envs)) : "arn:${local.part}:s3:::${var.state_bucket_name}/${local.state_key_root}/${e}/*"],
    ["arn:${local.part}:s3:::${var.state_bucket_name}/${local.state_key_root}/bootstrap*"],
  )
}

data "aws_iam_policy_document" "deny_other_state" {
  statement {
    sid       = "NoOtherEnvState"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = local.other_state
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

# Shared guardrail: no CI role can use the SSN key or read or set the SSN
# secrets (the HMAC pepper). Terraform never reads the pepper: it creates
# the secret but not its value, and an operator sets the value out of band.
# The key is matched by its alias, because its ARN doesn't exist when
# bootstrap runs. The SSN key policy (modules/ssn_vault) already gives no
# CI role any crypto on the key; these denies hold even if that policy is
# widened later.
data "aws_iam_policy_document" "deny_ssn_material" {
  statement {
    sid       = "NoSsnKeyEncrypt"
    effect    = "Deny"
    actions   = ["kms:Encrypt", "kms:ReEncrypt*"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [local.ssn_key_alias]
    }
  }

  # Creating a secret with this key makes Secrets Manager run a throwaway
  # GenerateDataKey and Decrypt as the caller, with SecretVersionId
  # RequestToValidateKeyAccess. The apply role creates the pepper secret in
  # a new environment, so only that check gets through. The two statements
  # deny any call made outside Secrets Manager, and any call that isn't
  # that check.
  statement {
    sid       = "NoSsnKeyOutsideSecretsManager"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [local.ssn_key_alias]
    }
    condition {
      test     = "StringNotEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "NoSsnKeyExceptKeyCheck"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [local.ssn_key_alias]
    }
    condition {
      test     = "StringNotEquals"
      variable = "kms:EncryptionContext:SecretVersionId"
      values   = ["RequestToValidateKeyAccess"]
    }
  }

  statement {
    sid       = "NoSsnSecretValues"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = [local.ssn_secrets]
  }
}
