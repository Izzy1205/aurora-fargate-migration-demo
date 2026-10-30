# Permissions boundary for every role the main stack creates. A role's
# effective permissions are its own policies AND this boundary, so even if the
# terraform role puts AdministratorAccess on a new role, the role still can't
# do more than what's listed here. Anything not listed is out of reach,
# including all of IAM.
#
# This covers what the ECS execution roles, the flow logs role and the app
# task role (payment queue and SSN token service) actually use. The migrate task role has no
# policies. If the main stack ever needs a role that does more, the boundary
# has to grow here first, by hand, and bootstrap has to be applied again.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource scoping
  }

  statement {
    sid = "PullProjectImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:${local.part}:ecr:${local.region}:${local.account}:repository/${local.p}/*"]
  }

  statement {
    sid     = "WriteProjectLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [
      "arn:${local.part}:logs:${local.region}:${local.account}:log-group:/ecs/${local.p}/*",
      "arn:${local.part}:logs:${local.region}:${local.account}:log-group:/${local.p}/*",
    ]
  }

  # The execution roles inject the DB credentials at task start. Each role's
  # own policy narrows this to the one secret its task needs.
  statement {
    sid     = "ReadDbSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:${local.part}:secretsmanager:${local.region}:${local.account}:secret:rds!*",
      "arn:${local.part}:secretsmanager:${local.region}:${local.account}:secret:${local.p}/db/*",
    ]
  }

  statement {
    sid       = "DecryptSecretViaSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }

  # The app task sends and consumes payment requests. Project queues only.
  # ChangeMessageVisibility is allowed here so the app team can extend a
  # message's timeout later without another bootstrap change; the task role
  # itself doesn't grant it yet.
  statement {
    sid = "UseProjectQueues"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = ["arn:${local.part}:sqs:${local.region}:${local.account}:${local.p}-*"]
  }

  # The queues are encrypted with a project key. The key ARN doesn't exist
  # yet when bootstrap runs, so this is limited to calls SQS makes instead.
  statement {
    sid       = "UseQueueKeyViaSqs"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sqs.${local.region}.amazonaws.com"]
    }
  }
  # The SSN token service (app task role for now). The key ARN and the
  # Aurora cluster resource ID don't exist when bootstrap runs, so the key is
  # matched by its alias and the DB login by its username.
  # These four SSN statements move to the vault boundary below. They stay
  # here until the app stops calling KMS itself (the cutover PR), then they
  # come out of this boundary in a bootstrap change.
  statement {
    sid       = "DescribeSsnKey"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.p}-ssn"]
    }
  }

  statement {
    sid       = "UseSsnKeyWithPurpose"
    actions   = ["kms:Encrypt", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.p}-ssn"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:purpose"
      values   = ["ssn"]
    }
  }

  # The HMAC pepper. Its KMS decrypt goes through Secrets Manager, which
  # DecryptSecretViaSecretsManager above already covers.
  statement {
    sid       = "ReadSsnPepper"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.part}:secretsmanager:${local.region}:${local.account}:secret:${local.p}/ssn/*"]
  }

  statement {
    sid       = "SsnVaultDbLogin"
    actions   = ["rds-db:connect"]
    resources = ["arn:${local.part}:rds-db:${local.region}:${local.account}:dbuser:*/ssn_vault_login"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "${local.p}-workload-boundary"
  description = "Permissions boundary for roles the main stack creates."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# Permissions boundary for the SSN token service's own roles
# (<name_prefix>-ssn-vault-execution and -task, created by the app layer).
# Only roles named <name_prefix>-ssn-vault-* may carry it, and those roles
# may not get anything else (see the apply role in roles.tf). It has the SSN
# key, the pepper secret and the ssn_vault_login DB login, plus image pull
# and its own log group. No queues, no DB password secrets.
#
# Once the app no longer calls KMS itself, the SSN statements come out of
# the workload boundary, and only this boundary allows them.
data "aws_iam_policy_document" "vault_boundary" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource scoping
  }

  statement {
    sid = "PullProjectImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["arn:${local.part}:ecr:${local.region}:${local.account}:repository/${local.p}/*"]
  }

  statement {
    sid       = "WriteVaultLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.vault_log_group}:*"]
  }

  # Same alias and purpose=ssn matching as the workload boundary, because
  # the key ARN doesn't exist when bootstrap runs.
  statement {
    sid       = "DescribeSsnKey"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [local.ssn_key_alias]
    }
  }

  statement {
    sid       = "UseSsnKeyWithPurpose"
    actions   = ["kms:Encrypt", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [local.ssn_key_alias]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:purpose"
      values   = ["ssn"]
    }
  }

  # The pepper secret is encrypted with the SSN key. Decrypt through
  # Secrets Manager only, and only on that key.
  statement {
    sid       = "DecryptPepperViaSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [local.ssn_key_alias]
    }
  }

  # The pepper only, not the whole <name_prefix>/ssn/ path. Secrets
  # Manager adds a 6 character suffix to the name in the ARN.
  statement {
    sid       = "ReadSsnPepper"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.part}:secretsmanager:${local.region}:${local.account}:secret:${local.p}/ssn/hmac-pepper-??????"]
  }

  statement {
    sid       = "SsnVaultDbLogin"
    actions   = ["rds-db:connect"]
    resources = ["arn:${local.part}:rds-db:${local.region}:${local.account}:dbuser:*/ssn_vault_login"]
  }
}

resource "aws_iam_policy" "vault_boundary" {
  name        = "${local.p}-ssn-vault-boundary"
  description = "Permissions boundary for the SSN token service roles only."
  policy      = data.aws_iam_policy_document.vault_boundary.json
}
