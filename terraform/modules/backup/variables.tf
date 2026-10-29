variable "name_prefix" {
  description = "Prefix for every name, e.g. migdemo-testing."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of the Aurora cluster to back up."
  type        = string
}

variable "backup_role_name" {
  description = "Name of the role AWS Backup runs as. Bootstrap creates it, so the stack never has to make a role outside the workload boundary."
  type        = string
}

# Backup jobs fail near the RDS backup/maintenance window (03:00-11:00 UTC).
# 17:00 UTC is always clear.
variable "schedule" {
  description = "When the daily backup starts, as an AWS Backup cron expression in UTC."
  type        = string
  default     = "cron(0 17 * * ? *)"
}

variable "retention_days" {
  description = "Days to keep each backup in the home region."
  type        = number
  default     = 7

  validation {
    condition     = var.retention_days >= 1 && floor(var.retention_days) == var.retention_days
    error_message = "retention_days must be a whole number of days, at least 1."
  }
}

variable "dr_retention_days" {
  description = "Days to keep each copy in the DR region."
  type        = number
  default     = 7

  validation {
    condition     = var.dr_retention_days >= 1 && floor(var.dr_retention_days) == var.dr_retention_days
    error_message = "dr_retention_days must be a whole number of days, at least 1."
  }
}
