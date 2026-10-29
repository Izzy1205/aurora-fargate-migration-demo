output "vault_name" {
  description = "Backup vault in the home region."
  value       = aws_backup_vault.home.name
}

output "dr_vault_arn" {
  description = "Backup vault in the DR region that holds the copies."
  value       = aws_backup_vault.dr.arn
}

output "dr_region" {
  description = "Region the copies go to."
  value       = data.aws_region.dr.region
}

output "dr_kms_key_arn" {
  description = "Customer managed key that encrypts the copies in the DR region."
  value       = aws_kms_key.dr.arn
}

output "plan_id" {
  description = "AWS Backup plan ID."
  value       = aws_backup_plan.this.id
}
