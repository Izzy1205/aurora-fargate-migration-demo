# Separate logins for the app and for Flyway, so neither one runs as the
# Aurora master user. The master stays managed by RDS and is only read by the
# one-off db-logins task (modules/ecs), which creates these two roles and
# sets their passwords from the secrets below.
#
# The passwords never land in state or in a plan: random_password is
# ephemeral and the secret value is write-only. Terraform writes the value
# once and only reads the version metadata back, so no CI role ever needs
# GetSecretValue on these secrets. To rotate, bump login_password_version,
# apply, then run a deploy so db-logins sets the new passwords and the app
# and Flyway tasks pick them up.

locals {
  db_logins = {
    app = {
      username    = var.app_username
      description = "App login: read and write rows only, no DDL."
    }
    migrator = {
      username    = var.migrator_username
      description = "Flyway login: owns the schema and runs DDL."
    }
  }
}

ephemeral "random_password" "db_login" {
  for_each = local.db_logins

  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "db_login" {
  #checkov:skip=CKV2_AWS_57:rotated by bumping login_password_version, then a deploy re-runs db-logins
  #checkov:skip=CKV_AWS_149:AWS managed key, same trade-off as the rest of the stack (see .checkov.yaml)
  for_each = local.db_logins

  name                    = "${var.name_prefix}/db/${each.key}"
  description             = each.value.description
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "db_login" {
  for_each = local.db_logins

  secret_id = aws_secretsmanager_secret.db_login[each.key].id
  secret_string_wo = jsonencode({
    username = each.value.username
    password = ephemeral.random_password.db_login[each.key].result
  })
  secret_string_wo_version = var.login_password_version
}
