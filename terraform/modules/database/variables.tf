variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the DB subnet group."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the cluster."
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
}

variable "min_capacity" {
  description = "Minimum ACUs (0 enables auto-pause)."
  type        = number
}

variable "max_capacity" {
  description = "Maximum ACUs."
  type        = number
}

variable "seconds_until_auto_pause" {
  description = "Idle seconds before pausing. Only used when min_capacity is 0."
  type        = number
}

variable "db_name" {
  description = "Initial database name."
  type        = string
}

variable "master_username" {
  description = "Master username. The password is generated and stored by RDS in Secrets Manager."
  type        = string
  default     = "demo_admin"
}

variable "iam_database_authentication_enabled" {
  description = "Turn on IAM database auth. Free to enable; the demo app still uses the managed secret."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the exported Postgres log group."
  type        = number
  default     = 7
}
