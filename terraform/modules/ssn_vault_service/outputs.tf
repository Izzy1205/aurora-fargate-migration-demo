output "service_name" {
  description = "Vault ECS service name."
  value       = aws_ecs_service.vault.name
}

output "task_family" {
  description = "Vault task definition family."
  value       = aws_ecs_task_definition.vault.family
}

output "container_name" {
  description = "Container in the vault task definition. deploy.yml swaps its image."
  value       = local.container
}

output "security_group_id" {
  description = "Vault task security group."
  value       = aws_security_group.vault.id
}

output "dns_name" {
  description = "Private DNS name of the vault. Resolves only inside the VPC."
  value       = "${aws_service_discovery_service.vault.name}.${aws_service_discovery_private_dns_namespace.this.name}"
}

output "base_url" {
  description = "URL the app will use to call the vault (PR 3)."
  value       = "http://${aws_service_discovery_service.vault.name}.${aws_service_discovery_private_dns_namespace.this.name}:${var.port}"
}

output "log_group_name" {
  description = "CloudWatch log group with the vault output."
  value       = aws_cloudwatch_log_group.vault.name
}

output "task_role_name" {
  description = "Vault task role name."
  value       = aws_iam_role.task.name
}
