output "kms_key_arn" {
  description = "SSN vault key ARN. Not in the task definition yet (see layers/app/main.tf)."
  value       = aws_kms_key.ssn.arn
}

output "hmac_pepper_secret_arn" {
  description = "Secret holding the HMAC pepper. ARN only, never the value."
  value       = aws_secretsmanager_secret.hmac_pepper.arn
}

output "task_policy_json" {
  description = "Policy for the token service task role."
  value       = data.aws_iam_policy_document.task.json
}
