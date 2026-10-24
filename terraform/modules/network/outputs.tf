output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB only)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (tasks and Aurora)."
  value       = aws_subnet.private[*].id
}

output "alb_security_group_id" {
  description = "ALB security group."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "App task security group."
  value       = aws_security_group.app.id
}

output "migration_security_group_id" {
  description = "Migration task security group."
  value       = aws_security_group.migration.id
}

output "db_security_group_id" {
  description = "Aurora security group."
  value       = aws_security_group.db.id
}
