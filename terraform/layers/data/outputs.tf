# Read by the app unit through a Terragrunt dependency block. Secret ARN
# only, never the value.

output "endpoint" {
  description = "Writer endpoint."
  value       = module.database.endpoint
}

output "port" {
  description = "Postgres port."
  value       = module.database.port
}

output "db_name" {
  description = "Database name."
  value       = module.database.db_name
}

output "db_secret_arn" {
  description = "ARN of the RDS-managed secret (ARN only, not the value)."
  value       = module.database.master_user_secret_arn
}

output "aurora_cluster_identifier" {
  description = "Aurora cluster identifier."
  value       = module.database.cluster_identifier
}
