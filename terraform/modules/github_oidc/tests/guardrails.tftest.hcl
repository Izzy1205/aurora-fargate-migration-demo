# Plan-only checks on the CI role policies. No AWS calls: the provider uses
# placeholder keys with every remote check skipped, and the few values that
# need AWS are overridden. Run: terraform init -backend=false && terraform test

provider "aws" {
  region                      = "us-east-2"
  access_key                  = "placeholder"
  secret_key                  = "placeholder"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "111111111111" }
}

override_data {
  target = data.aws_partition.current
  values = { partition = "aws" }
}

override_resource {
  target          = aws_iam_openid_connect_provider.github
  override_during = plan
  values          = { arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com" }
}

override_resource {
  target          = aws_iam_policy.workload_boundary
  override_during = plan
  values          = { arn = "arn:aws:iam::111111111111:policy/migdemo-testing-workload-boundary" }
}

override_resource {
  target          = aws_iam_policy.vault_boundary
  override_during = plan
  values          = { arn = "arn:aws:iam::111111111111:policy/migdemo-testing-ssn-vault-boundary" }
}

override_resource {
  target          = aws_iam_role.backup
  override_during = plan
  values          = { arn = "arn:aws:iam::111111111111:role/service-role/migdemo-testing-backup" }
}

variables {
  name_prefix          = "migdemo-testing"
  environment          = "testing"
  aws_region           = "us-east-2"
  github_repo          = "someone/aurora-fargate-migration-demo"
  plan_environment     = "testing-infra-plan"
  infra_environment    = "testing-infra"
  app_environment      = "testing-app"
  create_oidc_provider = true
  state_bucket_name    = "example-tfstate"
  state_key_prefix     = "aurora-fargate-migration-demo/testing"
  trust_pull_request   = true
}

run "testing_denies" {
  command = plan

  # The apply policy isn't known at plan (it names the boundary ARNs), so
  # its checks read the shared documents it is built from.
  assert {
    condition = alltrue([
      for p in [aws_iam_role_policy.plan.policy, aws_iam_role_policy.deploy.policy] :
      length(setintersection(
        toset([for s in jsondecode(p).Statement : s.Sid]),
        toset(["NoOtherEnvSecretsByName", "NoOtherEnvSecretsByTag", "NoOtherEnvSsnKey", "NoOtherEnvKeyAdmin", "NoRoleChaining"]),
      )) == 5
    ])
    error_message = "Plan and deploy need the cross-env and role chaining denies."
  }

  # H1: peers by name, own env untouched.
  assert {
    condition = (
      toset([for s in jsondecode(data.aws_iam_policy_document.deny_peer_envs.json).Statement : s.Resource if s.Sid == "NoOtherEnvSecretsByName"][0]) ==
      toset(["arn:aws:secretsmanager:*:111111111111:secret:migdemo-production*", "arn:aws:secretsmanager:*:111111111111:secret:migdemo-stage*"])
    )
    error_message = "NoOtherEnvSecretsByName must list exactly the two peer prefixes."
  }

  # H2: peer SSN aliases only.
  assert {
    condition = (
      toset([for s in jsondecode(data.aws_iam_policy_document.deny_peer_envs.json).Statement : s.Condition["ForAnyValue:StringEquals"]["kms:ResourceAliases"] if s.Sid == "NoOtherEnvSsnKey"][0]) ==
      toset(["alias/migdemo-production-ssn", "alias/migdemo-stage-ssn"])
    )
    error_message = "NoOtherEnvSsnKey must match the peer SSN aliases, not testing's."
  }

  # H3: no CI role can change the vault roles' trust.
  assert {
    condition = (
      [for s in jsondecode(data.aws_iam_policy_document.deny_role_escalation.json).Statement : s.Resource if s.Sid == "NoVaultTrustChanges"][0] ==
      "arn:aws:iam::111111111111:role/migdemo-testing-ssn-vault-*"
    )
    error_message = "NoVaultTrustChanges must cover the vault roles."
  }

  # M2: peer saved plans and old versions.
  assert {
    condition = alltrue([
      for r in [
        "arn:aws:s3:::example-tfstate/plans/*/stage/*",
        "arn:aws:s3:::example-tfstate/plans/*/production/*",
        "arn:aws:s3:::example-tfstate/aurora-fargate-migration-demo/stage/*",
        "arn:aws:s3:::example-tfstate/aurora-fargate-migration-demo/bootstrap*",
      ] : contains([for s in jsondecode(aws_iam_role_policy.plan.policy).Statement : s.Resource if s.Sid == "NoOtherEnvState"][0], r)
    ])
    error_message = "NoOtherEnvState must cover peer state, bootstrap state and peer saved plans."
  }

  assert {
    condition     = !anytrue([for s in jsondecode(aws_iam_role_policy.plan.policy).Statement : s.Sid == "NoOtherEnvState" && anytrue([for r in s.Resource : strcontains(r, "/testing/")])])
    error_message = "NoOtherEnvState must not deny testing's own state or plans."
  }

  # State key: every role is denied it outside S3.
  assert {
    condition = alltrue([
      for p in [aws_iam_role_policy.plan.policy, aws_iam_role_policy.deploy.policy] :
      contains([for s in jsondecode(p).Statement : s.Sid], "NoStateKeyOutsideS3")
    ])
    error_message = "Plan and deploy need NoStateKeyOutsideS3."
  }

  # Apply's JSON isn't known at plan, but its source documents are.
  assert {
    condition = contains(
      data.aws_iam_policy_document.apply.source_policy_documents,
      data.aws_iam_policy_document.deny_state_key_outside_s3.json,
    )
    error_message = "Apply needs NoStateKeyOutsideS3."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.deny_state_key_outside_s3.json).Statement : (
        s.Effect == "Deny" &&
        s.Condition["ForAnyValue:StringEquals"]["kms:ResourceAliases"] == "alias/migdemo-tfstate" &&
        s.Condition["StringNotLike"]["kms:ViaService"] == "s3.*.amazonaws.com" &&
        contains(s.Action, "kms:Decrypt") && contains(s.Action, "kms:GenerateDataKey*")
      )
    ])
    error_message = "NoStateKeyOutsideS3 must deny the tfstate alias for any call not made through S3."
  }

  # The plan role stays read only: no KMS allow of its own. It reaches the
  # state key only through S3, from the key policy.
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.plan.policy).Statement :
      s.Effect == "Allow" && anytrue([for a in flatten([s.Action]) : startswith(a, "kms:")])
    ])
    error_message = "The plan role must not get a KMS allow."
  }

  # M3: apply can only create, change or delete services in its own cluster.
  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.deny_services_outside_cluster.json).Statement : (
        s.Effect == "Deny" &&
        toset(s.Action) == toset(["ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService"]) &&
        s.NotResource == "arn:aws:ecs:us-east-2:111111111111:service/migdemo-testing-cluster/*"
      ) if s.Sid == "NoServicesOutsideOwnCluster"
    ]) && contains(data.aws_iam_policy_document.apply.source_policy_documents, data.aws_iam_policy_document.deny_services_outside_cluster.json)
    error_message = "Apply must be denied services outside migdemo-testing-cluster."
  }

  # The app layer's services must sit inside that cluster, or apply breaks.
  assert {
    condition     = alltrue([for a in local.service_arns : startswith(a, "arn:aws:ecs:us-east-2:111111111111:service/migdemo-testing-cluster/")])
    error_message = "The deploy role's services must be in the cluster apply is allowed."
  }

  # L1: Secrets Manager decrypt only for callers in this account.
  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.workload_boundary.json).Statement : (
        s.Condition["StringEquals"]["kms:ViaService"] == "secretsmanager.us-east-2.amazonaws.com" &&
        s.Condition["StringEquals"]["kms:CallerAccount"] == "111111111111"
      ) if s.Sid == "DecryptSecretViaSecretsManager"
    ]) && contains([for s in jsondecode(data.aws_iam_policy_document.workload_boundary.json).Statement : s.Sid], "DecryptSecretViaSecretsManager")
    error_message = "DecryptSecretViaSecretsManager needs kms:ViaService and kms:CallerAccount."
  }

  # M4: DenyCiBucketAdmin (state-bucket/policy.tf) and DenyCiKeyAdmin
  # (state-bucket/kms.tf) match role/migdemo-*-github-*. A CI role named
  # anything else would slip past both.
  assert {
    condition = alltrue([
      for n in [aws_iam_role.plan.name, aws_iam_role.apply.name, aws_iam_role.deploy.name] :
      can(regex("^migdemo-[^/]+-github-[^/]+$", n))
    ])
    error_message = "CI role names must match migdemo-*-github-*, the pattern the state bucket and key policies deny."
  }
}

run "production_peers" {
  command = plan

  variables {
    name_prefix          = "migdemo-production"
    environment          = "production"
    plan_environment     = "production-infra-plan"
    infra_environment    = "production-infra"
    app_environment      = "production-app"
    state_key_prefix     = "aurora-fargate-migration-demo/production"
    trust_pull_request   = false
    promote_from_prefix  = "migdemo-stage"
    create_oidc_provider = true
  }

  assert {
    condition = (
      toset([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "NoOtherEnvSecretsByName"][0]) ==
      toset(["arn:aws:secretsmanager:*:111111111111:secret:migdemo-stage*", "arn:aws:secretsmanager:*:111111111111:secret:migdemo-testing*"])
    )
    error_message = "Production must deny stage and testing secrets."
  }

  # Promotion still pulls the source env's ECR repos (same account by default).
  assert {
    condition     = contains([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Sid], "PromotionSourcePull")
    error_message = "Promotion pull must stay."
  }

  assert {
    condition = alltrue([
      for r in [for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "PromotionSourcePull"][0] :
      startswith(r, "arn:aws:ecr:us-east-2:111111111111:repository/migdemo-stage/")
    ])
    error_message = "Default promote source ARNs must stay in this account."
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Sid], "PromotionSourceServiceRead")
    error_message = "Service read moved to promote.yml resolve under the source plan role."
  }

  assert {
    condition = alltrue([
      for n in [aws_iam_role.plan.name, aws_iam_role.apply.name, aws_iam_role.deploy.name] :
      can(regex("^migdemo-[^/]+-github-[^/]+$", n))
    ])
    error_message = "CI role names must match migdemo-*-github-*, the pattern the state bucket and key policies deny."
  }
}

run "promote_cross_account" {
  command = plan

  variables {
    name_prefix              = "migdemo-production"
    environment              = "production"
    plan_environment         = "production-infra-plan"
    infra_environment        = "production-infra"
    app_environment          = "production-app"
    state_key_prefix         = "aurora-fargate-migration-demo/production"
    trust_pull_request       = false
    promote_from_prefix      = "migdemo-stage"
    promote_from_account_id  = "222222222222"
    create_oidc_provider     = true
  }

  assert {
    condition = alltrue([
      for r in [for s in jsondecode(aws_iam_role_policy.deploy.policy).Statement : s.Resource if s.Sid == "PromotionSourcePull"][0] :
      startswith(r, "arn:aws:ecr:us-east-2:222222222222:repository/migdemo-stage/")
    ])
    error_message = "promote_from_account_id must win over the local account in source ECR ARNs."
  }
}

run "bad_prefix" {
  command = plan
  variables {
    name_prefix = "migdemo-stage"
  }
  expect_failures = [var.name_prefix]
}
