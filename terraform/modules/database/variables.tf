variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the DB subnet group."
  type        = list(string)
}

variable "availability_zones" {
  description = "AZs of the subnets in subnet_ids. Readers are placed in the ones the writer isn't in."
  type        = list(string)
}

variable "instance_count" {
  description = "Aurora instances, writer included. 1 is writer only; 2 adds a reader in another AZ to fail over to."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 16 && floor(var.instance_count) == var.instance_count
    error_message = "Use a whole number from 1 to 16 (one writer plus up to 15 readers)."
  }

  validation {
    condition     = var.instance_count == 1 || length(distinct(var.availability_zones)) >= 2
    error_message = "A reader needs a second AZ in the subnet group, or it would share the writer's AZ."
  }
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
  description = "Master username, kept for break-glass and the db-logins task. RDS generates the password and stores it in Secrets Manager."
  type        = string
  default     = "demo_admin"
}

variable "iam_database_authentication_enabled" {
  description = "Turn on IAM database auth. Free to enable; the app and Flyway still log in with passwords."
  type        = bool
  default     = true
}

# Days of point in time restore. Storage up to cluster size is free.
variable "backup_retention_period" {
  description = "Days Aurora keeps its automated backups (1 to 35)."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35 && floor(var.backup_retention_period) == var.backup_retention_period
    error_message = "Use a whole number from 1 to 35."
  }
}

variable "log_retention_days" {
  description = "Retention for the exported Postgres log group."
  type        = number
  default     = 7
}

variable "app_username" {
  description = "Postgres role the app logs in as. Gets row access only."
  type        = string
  default     = "app_user"
}

variable "migrator_username" {
  description = "Postgres role Flyway logs in as. Owns the schema."
  type        = string
  default     = "migrator"
}

variable "login_password_version" {
  description = "Bump to generate new app and Flyway passwords on the next apply."
  type        = number
  default     = 1
}

variable "secret_recovery_window_days" {
  description = "Days a deleted login secret can be restored. 0 deletes right away, so a rebuild the same day can reuse the name."
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "Use 0, or 7 to 30 days."
  }
}
