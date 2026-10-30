output "kms_key_arn" {
  description = "SSN vault key, passed to the app as SSN_KMS_KEY_ID."
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
