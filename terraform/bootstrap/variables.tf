variable "aws_region" {
  description = "Region of the Terragrunt environment these roles serve. Must match aws_region in its env.hcl."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Must match project in terraform/root.hcl."
  type        = string
  default     = "migdemo"
}

variable "environment" {
  description = "Must match environment in terraform/environments/<env>/env.hcl. Only testing is deployed."
  type        = string
  default     = "testing"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI roles, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "Use the form owner/name."
  }
}

variable "github_plan_environment" {
  description = "GitHub environment the deploy.yml plan job runs in. No reviewer, main only."
  type        = string
  default     = "testing-infra-plan"
}

variable "github_infra_environment" {
  description = "GitHub environment the terraform apply job runs in."
  type        = string
  default     = "testing-infra"
}

variable "github_app_environment" {
  description = "GitHub environment the migrate and deploy job runs in."
  type        = string
  default     = "testing-app"
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "State bucket. The plan role gets read and lock access to this environment's unit state keys."
  type        = string
}

variable "state_key_prefix" {
  description = "Key prefix of the Terragrunt unit states. Must match the key in terraform/root.hcl. The environment name is added after it."
  type        = string
  default     = "aurora-fargate-migration-demo"
}

variable "github_subject_prefixes" {
  description = <<-EOT
    Extra OIDC sub prefixes to trust. Repos that use GitHub's immutable subject
    format send repo:OWNER@OWNER_ID/NAME@REPO_ID. Find yours with:
    gh api repos/OWNER/NAME/actions/oidc/customization/sub
  EOT
  type        = list(string)
  default     = []
}
