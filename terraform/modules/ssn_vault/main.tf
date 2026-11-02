# The SSN token service's key and HMAC pepper.
#
# The key encrypts the SSN in the ssn_vault table. Every call must carry the
# encryption context purpose=ssn, so this key can't be used as a general
# purpose encrypt/decrypt service. The pepper secret holds the HMAC key for
# claimant.ssn_hmac and wage_quarter.ssn_hmac. Terraform creates the secret
# but never its value: an operator sets it once, out of band, and it must
# never change (changing it breaks every hash match).
#
# Cost: $1 a month for the key, $0.40 for the secret, both prorated.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "ssn" {
  description             = "${var.name_prefix} SSN vault"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.ssn_key.json
}

resource "aws_kms_alias" "ssn" {
  name          = "alias/${var.name_prefix}-ssn"
  target_key_id = aws_kms_key.ssn.key_id
}

locals {
  # Built from the name, not the secret's ARN: the secret is encrypted with
  # this key, so the key policy can't refer to it without a cycle. Secrets
  # Manager adds a 6 character suffix to the name in the ARN.
  pepper_arn_pattern = "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/ssn/hmac-pepper-??????"
  account_root       = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
  secretsmanager_via = "secretsmanager.${data.aws_region.current.region}.amazonaws.com"
}

# Only the vault task role can use this key on SSN data. The account (and so
# IAM, including the CI apply role) can manage the key but not encrypt or
# decrypt with it. Management stays with the account on purpose: KMS refuses
# a policy that would stop the caller from changing it again, and Terraform
# has to keep managing, rotating and deleting the key. The CI roles also
# carry explicit denies on this key and the ssn/ secrets (bootstrap,
# modules/github_oidc).
data "aws_iam_policy_document" "ssn_key" {
  # Same reasoning as the queue key: in a key policy "*" is this key only.
  #checkov:skip=CKV_AWS_109:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_111:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_356:Key policy, "*" is this key only

  # Manage the key, no crypto. No CreateGrant either, since a grant could
  # hand out Decrypt.
  statement {
    sid = "KeyAdministration"
    actions = [
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
      "kms:Describe*",
      "kms:Get*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Enable*",
      "kms:Disable*",
      "kms:RotateKeyOnDemand",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:RevokeGrant",
      "kms:RetireGrant",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  # The vault encrypts and decrypts the SSN, only with purpose=ssn.
  statement {
    sid       = "VaultSsnWithPurpose"
    actions   = ["kms:Encrypt", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.vault_task_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:purpose"
      values   = ["ssn"]
    }
  }

  statement {
    sid       = "VaultDescribe"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.vault_task_role_arn]
    }
  }

  # The vault reads the pepper. Secrets Manager decrypts it on the vault's
  # behalf with the secret's ARN in the encryption context.
  statement {
    sid       = "VaultPepperViaSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [var.vault_task_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.secretsmanager_via]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [local.pepper_arn_pattern]
    }
  }

  # An operator sets the pepper once, out of band (put-secret-value). That
  # needs a new data key through Secrets Manager. It can't read the pepper
  # back: no Decrypt here. The CI roles are denied this in IAM.
  statement {
    sid       = "SetPepperViaSecretsManager"
    actions   = ["kms:GenerateDataKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.secretsmanager_via]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [local.pepper_arn_pattern]
    }
  }

  # When a secret is created with this key, Secrets Manager checks the
  # caller can use it with a throwaway call (SecretVersionId
  # RequestToValidateKeyAccess). Terraform creates the pepper secret, so
  # it needs this. Nothing real is encrypted under that context.
  statement {
    sid       = "SecretsManagerKeyCheck"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.secretsmanager_via]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:SecretVersionId"
      values   = ["RequestToValidateKeyAccess"]
    }
  }
}

resource "aws_secretsmanager_secret" "hmac_pepper" {
  #checkov:skip=CKV2_AWS_57:must never rotate, a new pepper breaks every ssn_hmac match
  name                    = "${var.name_prefix}/ssn/hmac-pepper"
  description             = "HMAC-SHA256 key for ssn_hmac, hex, at least 32 bytes. Value set out of band."
  kms_key_id              = aws_kms_key.ssn.arn
  recovery_window_in_days = var.secret_recovery_window_days
}

# What the token service needs at runtime, all read by the vault service
# (modules/ssn_vault_service) with its own task role at startup or per
# request. No task definition env or secrets, because changing those
# replaces the Terraform-owned task definition and the deploy delete gate
# blocks that.
data "aws_iam_policy_document" "task" {
  # Encrypt and decrypt the SSN itself, only with purpose=ssn in the
  # encryption context.
  statement {
    sid       = "SsnKeyWithPurpose"
    actions   = ["kms:Encrypt", "kms:Decrypt"]
    resources = [aws_kms_key.ssn.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:purpose"
      values   = ["ssn"]
    }
  }

  # The vault finds the key by its alias and records the key ARN on each row.
  statement {
    sid       = "SsnKeyDescribe"
    actions   = ["kms:DescribeKey"]
    resources = [aws_kms_key.ssn.arn]
  }

  # Read the HMAC pepper. The secret is encrypted with the SSN key, and
  # Secrets Manager decrypts it with its own encryption context, so that
  # Decrypt is allowed only through Secrets Manager.
  statement {
    sid       = "ReadPepper"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.hmac_pepper.arn]
  }

  statement {
    sid       = "SsnKeyViaSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.ssn.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  # Sign in to Aurora as the vault login with an IAM auth token. No
  # password exists for this login, so there is no secret to inject.
  statement {
    sid       = "VaultDbLogin"
    actions   = ["rds-db:connect"]
    resources = ["arn:${data.aws_partition.current.partition}:rds-db:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:dbuser:${var.db_cluster_resource_id}/${var.vault_db_username}"]
  }
}

# For the app task role. The app only forwards /ssn to the vault service, so
# it must never use the SSN key, read the pepper or sign in as the vault
# login. Explicit denies, so no allow added later (role or boundary) can
# give that back. Scoped to this key ARN, the <name_prefix>/ssn/ secret path
# and the vault login, so nothing else the app uses is caught: its DB secrets
# use the AWS managed key and other paths, the queue has its own key, and
# its DB login is app_user.
data "aws_iam_policy_document" "app_deny" {
  statement {
    sid    = "DenySsnKey"
    effect = "Deny"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = [aws_kms_key.ssn.arn]
  }

  statement {
    sid       = "DenySsnSecrets"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/ssn/*"]
  }

  # Any cluster, not just this one: the app has no reason to be this login
  # anywhere.
  statement {
    sid       = "DenyVaultDbLogin"
    effect    = "Deny"
    actions   = ["rds-db:connect"]
    resources = ["arn:${data.aws_partition.current.partition}:rds-db:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:dbuser:*/${var.vault_db_username}"]
  }
}
