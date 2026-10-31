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

data "aws_iam_policy_document" "ssn_key" {
  # Same reasoning as the queue key: in a key policy "*" is this key only.
  #checkov:skip=CKV_AWS_109:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_111:Key policy, "*" is this key only
  #checkov:skip=CKV_AWS_356:Key policy, "*" is this key only
  statement {
    sid       = "AccountAccessThroughIam"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
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
