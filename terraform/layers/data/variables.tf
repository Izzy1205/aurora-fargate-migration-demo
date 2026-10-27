variable "project" {
  description = "Short project name, used as a name prefix and a tag."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "Use 3 to 21 lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "Environment name, used as a name prefix and a tag."
  type        = string
}

# Only read by the provider.tf that Terragrunt generates, which tflint does
# not see when it lints this folder on its own.
# tflint-ignore: terraform_unused_declarations
variable "owner" {
  description = "Owner tag value. Terragrunt sets it from MIGDEMO_OWNER."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the DB subnet group. From the network unit."
  type        = list(string)
}

variable "db_security_group_id" {
  description = "Aurora security group. From the network unit."
  type        = string
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL version. Scale to zero needs 16.3+ (or 15.7+, 14.12+, 13.15+)."
  type        = string
}

variable "aurora_min_capacity" {
  description = "Minimum ACUs. 0 lets the cluster pause when idle."
  type        = number
}

variable "aurora_max_capacity" {
  description = "Maximum ACUs."
  type        = number
}

variable "aurora_seconds_until_auto_pause" {
  description = "Idle seconds before the cluster pauses (300 to 86400). Only used when min capacity is 0."
  type        = number
}

variable "db_name" {
  description = "Database name."
  type        = string
}
