output "cluster_identifier" {
  description = "Cluster identifier."
  value       = aws_rds_cluster.this.cluster_identifier
}

output "cluster_arn" {
  description = "Cluster ARN. The backup plan selects the cluster by it."
  value       = aws_rds_cluster.this.arn
}

output "endpoint" {
  description = "Writer endpoint."
  value       = aws_rds_cluster.this.endpoint
}

# Points at the writer when there are no readers.
output "reader_endpoint" {
  description = "Reader endpoint."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "reader_identifiers" {
  description = "Reader instance identifiers. Empty when instance_count is 1."
  value       = aws_rds_cluster_instance.reader[*].identifier
}

output "port" {
  description = "Postgres port."
  value       = aws_rds_cluster.this.port
}

output "db_name" {
  description = "Database name."
  value       = aws_rds_cluster.this.database_name
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed master secret. Break-glass, and read only by the db-logins task."
  value       = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

output "app_secret_arn" {
  description = "ARN of the app login secret (username and password JSON)."
  value       = aws_secretsmanager_secret.db_login["app"].arn
}

output "migrator_secret_arn" {
  description = "ARN of the Flyway login secret (username and password JSON)."
  value       = aws_secretsmanager_secret.db_login["migrator"].arn
}

output "app_username" {
  description = "Postgres role the app logs in as."
  value       = var.app_username
}

output "migrator_username" {
  description = "Postgres role Flyway logs in as."
  value       = var.migrator_username
}

output "cluster_resource_id" {
  description = "Cluster resource ID (cluster-...), the part of an rds-db:connect ARN that names this cluster."
  value       = aws_rds_cluster.this.cluster_resource_id
}
