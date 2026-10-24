variable "aws_region" {
  description = "Region of the main stack."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Must match the main stack."
  type        = string
  default     = "migdemo"
}

variable "environment" {
  description = "Must match the main stack."
  type        = string
  default     = "demo"
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

variable "github_infra_environment" {
  description = "GitHub environment the terraform apply job runs in."
  type        = string
  default     = "production-infra"
}

variable "github_app_environment" {
  description = "GitHub environment the migrate and deploy job runs in."
  type        = string
  default     = "production-app"
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "State bucket. The plan role gets read and lock access to the main stack's key."
  type        = string
}

variable "state_key" {
  description = "Main stack state key. Must match backend.hcl."
  type        = string
  default     = "aurora-fargate-migration-demo/terraform.tfstate"
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
