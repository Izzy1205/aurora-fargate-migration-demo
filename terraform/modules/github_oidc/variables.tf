variable "name_prefix" {
  description = "Same project-environment prefix the main stack uses. Resource ARNs below are built from it."
  type        = string
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

variable "state_key" {
  description = "State object key of the main stack."
  type        = string
}

variable "plans_prefix" {
  description = "Key prefix in the state bucket where deploy.yml keeps saved plans."
  type        = string
  default     = "plans"
}
