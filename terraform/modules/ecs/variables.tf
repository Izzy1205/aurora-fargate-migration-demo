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

variable "domain_name" {
  description = "DNS name for the ALB, such as app.example.com. Set it with route53_zone_id to get a public ACM cert. Null uses a self-signed cert."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Public Route 53 hosted zone for domain_name. Holds the ACM validation records and the alias record. Required when domain_name is set."
  type        = string
  default     = null

  validation {
    condition     = var.domain_name == null || var.route53_zone_id != null
    error_message = "Set route53_zone_id when domain_name is set."
  }
}

variable "ssl_policy" {
  description = "ALB TLS security policy for the HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
}

variable "self_signed_validity_hours" {
  description = "Lifetime of the self-signed cert, used when domain_name is null."
  type        = number
  default     = 8760 # 1 year
}

variable "self_signed_early_renewal_hours" {
  description = "How long before expiry the next plan replaces the self-signed cert."
  type        = number
  default     = 720 # 30 days

  validation {
    condition     = var.self_signed_early_renewal_hours < var.self_signed_validity_hours
    error_message = "Early renewal has to start before the cert expires."
  }
}
