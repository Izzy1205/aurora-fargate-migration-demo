output "kms_key_arn" {
  description = "SSN vault key ARN. Not in any task definition (see layers/app/main.tf)."
  value       = aws_kms_key.ssn.arn
}

output "hmac_pepper_secret_arn" {
  description = "Secret holding the HMAC pepper. ARN only, never the value."
  value       = aws_secretsmanager_secret.hmac_pepper.arn
}

output "vault_db_username" {
  description = "Postgres login the token service signs in as with IAM auth."
  value       = var.vault_db_username
}

output "task_policy_json" {
  description = "Policy for the token service (vault) task role."
  value       = data.aws_iam_policy_document.task.json
}

output "app_deny_policy_json" {
  description = "Explicit denies for the app task role: SSN key, ssn/ secrets and the vault DB login."
  value       = data.aws_iam_policy_document.app_deny.json
}
