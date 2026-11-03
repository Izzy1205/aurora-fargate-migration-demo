output "bucket_name" {
  description = "State bucket name. Use for TF_STATE_BUCKET and state_bucket_name."
  value       = aws_s3_bucket.state.bucket
}

output "bucket_arn" {
  description = "State bucket ARN."
  value       = aws_s3_bucket.state.arn
}

output "bucket_region" {
  description = "State bucket region. Use for TF_STATE_REGION."
  value       = aws_s3_bucket.state.region
}

output "kms_key_arn" {
  description = "ARN of the bucket's default encryption key, or null when use_kms is false."
  value       = var.use_kms ? aws_kms_key.state[0].arn : null
}

output "kms_alias" {
  description = "Alias of the bucket's default encryption key, or null when use_kms is false."
  value       = var.use_kms ? aws_kms_alias.state[0].name : null
}
