# Read by the data and app units through Terragrunt dependency blocks.

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB only)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (tasks and Aurora)."
  value       = module.network.private_subnet_ids
}

# The data unit uses this to put the Aurora reader in a different AZ from
# the writer.
output "private_subnet_azs" {
  description = "AZs of the private subnets, in the same order as private_subnet_ids."
  value       = module.network.private_subnet_azs
}

output "alb_security_group_id" {
  description = "ALB security group."
  value       = module.network.alb_security_group_id
}

output "app_security_group_id" {
  description = "App task security group."
  value       = module.network.app_security_group_id
}

output "migration_security_group_id" {
  description = "Migration task security group."
  value       = module.network.migration_security_group_id
}

output "db_security_group_id" {
  description = "Aurora security group."
  value       = module.network.db_security_group_id
}
