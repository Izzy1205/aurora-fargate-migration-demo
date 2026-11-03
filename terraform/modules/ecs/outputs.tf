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

output "db_logins_task_family" {
  description = "Task definition family that creates the DB logins."
  value       = aws_ecs_task_definition.db_logins.family
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

output "app_host" {
  description = "Host name clients use: domain_name when set, otherwise the ALB DNS name."
  value       = coalesce(var.domain_name, aws_lb.this.dns_name)
}

output "certificate_arn" {
  description = "ACM cert on the HTTPS listener."
  value       = local.certificate_arn
}

output "certificate_self_signed" {
  description = "True when the HTTPS listener uses the self-signed cert, so clients need curl -k or --cacert."
  value       = !local.use_domain
}

output "self_signed_cert_pem" {
  description = "Public PEM of the self-signed cert, for curl --cacert. Null with a real domain."
  value       = local.use_domain ? null : tls_self_signed_cert.self_signed[0].cert_pem
}

# Alarm dimensions for the observability unit. CloudWatch wants the ARN
# suffix ("app/<name>/<id>" and "targetgroup/<name>/<id>"), not the full ARN.
output "alb_arn_suffix" {
  description = "ALB ARN suffix, the LoadBalancer dimension in CloudWatch."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "App target group ARN suffix, the TargetGroup dimension in CloudWatch."
  value       = aws_lb_target_group.app.arn_suffix
}

output "alb_arn" {
  description = "ALB ARN, for the WAF association."
  value       = aws_lb.this.arn
}

output "app_task_role_name" {
  description = "App task role name, for attaching policies from outside the module."
  value       = aws_iam_role.task["app"].name
}
