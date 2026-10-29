variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets for the ALB."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnets for Fargate tasks."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ALB security group."
  type        = string
}

variable "app_security_group_id" {
  description = "App task security group."
  type        = string
}

variable "app_port" {
  description = "Container port for the app."
  type        = number
}

variable "app_image" {
  description = "Full image reference for the first app task definition."
  type        = string
}

variable "migration_image" {
  description = "Full image reference for the first migration task definition."
  type        = string
}

variable "app_repository_arn" {
  description = "ECR repo ARN the app execution role may pull from."
  type        = string
}

variable "migration_repository_arn" {
  description = "ECR repo ARN the migration execution role may pull from."
  type        = string
}

variable "db_host" {
  description = "Aurora writer endpoint."
  type        = string
}

variable "db_port" {
  description = "Aurora port."
  type        = number
}

variable "db_name" {
  description = "Database name."
  type        = string
}

variable "master_secret_arn" {
  description = "ARN of the RDS-managed master secret. Only the db-logins task reads it."
  type        = string
}

variable "app_secret_arn" {
  description = "ARN of the app login secret, JSON with username and password keys."
  type        = string
}

variable "migrator_secret_arn" {
  description = "ARN of the Flyway login secret, JSON with username and password keys."
  type        = string
}

variable "app_username" {
  description = "Postgres role the app logs in as. db-logins creates it."
  type        = string
}

variable "migrator_username" {
  description = "Postgres role Flyway logs in as. db-logins creates it."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 7
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every IAM role this module creates."
  type        = string
}

variable "app_environment" {
  description = "Extra plain environment variables for the app container. No secrets here, those go in secrets."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}
