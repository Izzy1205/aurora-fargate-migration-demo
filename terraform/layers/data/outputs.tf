# Read by the app unit through a Terragrunt dependency block. Secret ARNs
# only, never the values.

output "endpoint" {
  description = "Writer endpoint."
  value       = module.database.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint. Points at the writer when there are no readers."
  value       = module.database.reader_endpoint
}

output "port" {
  description = "Postgres port."
  value       = module.database.port
}

output "db_name" {
  description = "Database name."
  value       = module.database.db_name
}

output "master_secret_arn" {
  description = "ARN of the RDS-managed master secret. Only the db-logins task reads it."
  value       = module.database.master_user_secret_arn
}

output "app_secret_arn" {
  description = "ARN of the app login secret."
  value       = module.database.app_secret_arn
}

output "migrator_secret_arn" {
  description = "ARN of the Flyway login secret."
  value       = module.database.migrator_secret_arn
}

output "app_username" {
  description = "Postgres role the app logs in as."
  value       = module.database.app_username
}

output "migrator_username" {
  description = "Postgres role Flyway logs in as."
  value       = module.database.migrator_username
}

output "aurora_cluster_identifier" {
  description = "Aurora cluster identifier."
  value       = module.database.cluster_identifier
}
