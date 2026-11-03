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
  description = "Must match environment in terraform/environments/<env>/env.hcl. Bootstrap is applied once per environment, each with its own state key (see backend.tf)."
  type        = string
  default     = "testing"

  validation {
    condition     = contains(["testing", "stage", "production"], var.environment)
    error_message = "Use testing, stage or production."
  }
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

  validation {
    condition     = !strcontains(lower(var.github_repo), "replace-me")
    error_message = "github_repo still has the REPLACE-ME placeholder. Set the real owner/name."
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

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name (3 to 63 lowercase letters, digits, dots, dashes)."
  }

  # A placeholder here gives the plan role a lock policy for the wrong
  # bucket, and the first promote fails with AccessDenied on the .tflock.
  validation {
    condition     = !strcontains(lower(var.state_bucket_name), "replace-me")
    error_message = "state_bucket_name still has the REPLACE-ME placeholder. Set the real bucket name."
  }
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
