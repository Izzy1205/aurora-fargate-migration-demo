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

variable "db_secret_arn" {
  description = "ARN of the RDS-managed secret with username and password keys."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 7
}
