output "cluster_identifier" {
  description = "Cluster identifier."
  value       = aws_rds_cluster.this.cluster_identifier
}

output "endpoint" {
  description = "Writer endpoint."
  value       = aws_rds_cluster.this.endpoint
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
  description = "ARN of the RDS-managed secret holding the master username and password."
  value       = aws_rds_cluster.this.master_user_secret[0].secret_arn
}
