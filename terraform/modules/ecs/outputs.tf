output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "App service name."
  value       = aws_ecs_service.app.name
}

output "service_arn" {
  description = "App service ARN."
  value       = aws_ecs_service.app.id
}

output "app_task_family" {
  description = "App task definition family."
  value       = aws_ecs_task_definition.app.family
}

output "migration_task_family" {
  description = "Migration task definition family."
  value       = aws_ecs_task_definition.migration.family
}

output "passable_role_arns" {
  description = "Execution and task role ARNs the deploy role may pass to ECS."
  value = concat(
    [for r in aws_iam_role.execution : r.arn],
    [for r in aws_iam_role.task : r.arn],
  )
}

output "migration_log_group_name" {
  description = "Log group for Flyway output."
  value       = aws_cloudwatch_log_group.migration.name
}

output "migration_log_group_arn" {
  description = "Log group ARN for Flyway output."
  value       = aws_cloudwatch_log_group.migration.arn
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.this.dns_name
}
