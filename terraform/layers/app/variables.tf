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

variable "app_port" {
  description = "Port the app container listens on."
  type        = number
}

variable "vpc_id" {
  description = "VPC ID. From the network unit."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the ALB. From the network unit."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets for Fargate tasks. From the network unit."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ALB security group. From the network unit."
  type        = string
}

variable "app_security_group_id" {
  description = "App task security group. From the network unit."
  type        = string
}

variable "migration_security_group_id" {
  description = "Flyway task security group. From the network unit, passed straight to an output for deploy.yml."
  type        = string
}

variable "db_host" {
  description = "Aurora writer endpoint. From the data unit."
  type        = string
}

variable "db_port" {
  description = "Aurora port. From the data unit."
  type        = number
}

variable "db_name" {
  description = "Database name. From the data unit."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the RDS-managed secret. From the data unit. ARN only, never the value."
  type        = string
}

variable "app_image_tag" {
  description = "Image tag for the first task definitions. CI registers new revisions with the commit SHA."
  type        = string
  default     = "bootstrap"
}

variable "app_desired_count" {
  description = "Tasks deploy.yml scales the service to after a release. Terraform keeps the service at 0 and ignores the count."
  type        = number
}

variable "budget_email" {
  description = "Email address that receives the budget alerts. Terragrunt sets it from MIGDEMO_BUDGET_EMAIL."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD."
  type        = number
}
