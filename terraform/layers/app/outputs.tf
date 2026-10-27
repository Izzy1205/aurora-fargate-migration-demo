# What CI needs to run the migration and roll the service. deploy.yml reads
# all of these from this one unit. Secret ARN only, never the value.

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
  value       = join(",", var.private_subnet_ids)
}

output "migration_security_group_id" {
  description = "Security group for the Flyway task."
  value       = var.migration_security_group_id
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

output "app_desired_count" {
  description = "Tasks to run after a release. Set per environment in env.hcl."
  value       = var.app_desired_count
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix. The observability unit uses it as an alarm dimension."
  value       = module.ecs.alb_arn_suffix
}

output "target_group_arn_suffix" {
  description = "App target group ARN suffix. The observability unit uses it as an alarm dimension."
  value       = module.ecs.target_group_arn_suffix
}

output "waf_web_acl_name" {
  description = "WAF web ACL name. The observability unit uses it as an alarm dimension."
  value       = module.waf.web_acl_name
}

output "waf_log_group" {
  description = "CloudWatch log group with the WAF logs."
  value       = module.waf.log_group_name
}

output "payment_queue_url" {
  description = "Payment requests queue URL. Also set on the app as PAYMENT_QUEUE_URL."
  value       = module.queue.queue_url
}

output "payment_queue_name" {
  description = "Payment requests queue name. The observability unit alarms on it."
  value       = module.queue.queue_name
}

output "payment_dlq_name" {
  description = "Payment requests dead letter queue name."
  value       = module.queue.dlq_name
}
