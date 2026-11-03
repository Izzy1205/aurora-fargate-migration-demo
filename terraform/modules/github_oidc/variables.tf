variable "name_prefix" {
  description = "Same project-environment prefix the main stack uses. Resource ARNs below are built from it."
  type        = string

  # The cross-env denies take the project from this prefix.
  validation {
    condition     = endswith(var.name_prefix, "-${var.environment}") && length(var.name_prefix) > length(var.environment) + 1
    error_message = "name_prefix must be <project>-<environment>."
  }
}

variable "aws_region" {
  description = "Region of the main stack."
  type        = string
}

variable "github_repo" {
  description = "owner/name of the repo allowed to assume these roles."
  type        = string
}

variable "github_subject_prefixes" {
  description = "Extra accepted sub prefixes, such as the immutable repo:OWNER@ID/NAME@ID form."
  type        = list(string)
  default     = []
}

variable "plan_environment" {
  description = "GitHub environment for the plan job in deploy.yml. No reviewer, main only."
  type        = string
}

variable "infra_environment" {
  description = "GitHub environment for the terraform apply job."
  type        = string
}

variable "app_environment" {
  description = "GitHub environment for the migrate and deploy job."
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider, or look up an existing one."
  type        = bool
}

variable "state_bucket_name" {
  description = "State bucket name."
  type        = string
}

variable "state_key_prefix" {
  description = "Key prefix that holds one environment's unit states, as <prefix>/<unit>/terraform.tfstate."
  type        = string
}

variable "plans_prefix" {
  description = "Key prefix in the state bucket where deploy.yml keeps saved plans."
  type        = string
  default     = "plans"
}

variable "environment" {
  description = "Environment name (testing, stage, production). Scopes the saved plans this env's plan role may write."
  type        = string

  validation {
    condition     = contains(["testing", "stage", "production"], var.environment)
    error_message = "Use testing, stage or production."
  }
}

variable "trust_pull_request" {
  description = "Let pull_request jobs assume the plan role. True for testing only; stage and production plan roles trust their plan environment only."
  type        = bool
  default     = false
}

variable "promote_from_prefix" {
  description = "name_prefix of the environment this one promotes images from (migdemo-testing for stage, migdemo-stage for production). Empty for testing, which builds its own."
  type        = string
  default     = ""

  validation {
    condition     = var.promote_from_prefix == "" || can(regex("^[a-z0-9]+-(testing|stage)$", var.promote_from_prefix))
    error_message = "Use an empty string or <project>-testing / <project>-stage."
  }
}
