# Everything CI needs to run the migration task and roll the service.
# No secret values are output; only the secret ARN.

output "app_url" {
  description = "Open this in the browser during the demo."
  value       = "http://${module.ecs.alb_dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs.cluster_name
}

output "app_service_name" {
  description = "ECS service name."
  value       = module.ecs.service_name
}

output "app_task_family" {
  description = "App task definition family."
  value       = module.ecs.app_task_family
}

output "migration_task_family" {
  description = "Flyway task definition family."
  value       = module.ecs.migration_task_family
}

output "private_subnet_ids_csv" {
  description = "Private subnets, comma separated, for run-task awsvpc config."
  value       = join(",", module.network.private_subnet_ids)
}

output "migration_security_group_id" {
  description = "Security group for the Flyway task."
  value       = module.network.migration_security_group_id
}

output "app_ecr_repository" {
  description = "App ECR repository name."
  value       = module.registry.repository_names["app"]
}

output "migration_ecr_repository" {
  description = "Flyway ECR repository name."
  value       = module.registry.repository_names["migrate"]
}

output "migration_log_group" {
  description = "CloudWatch log group with Flyway output."
  value       = module.ecs.migration_log_group_name
}

output "db_secret_arn" {
  description = "ARN of the RDS-managed secret (ARN only, not the value)."
  value       = module.database.master_user_secret_arn
}

output "aurora_cluster_identifier" {
  description = "Aurora cluster identifier."
  value       = module.database.cluster_identifier
}
