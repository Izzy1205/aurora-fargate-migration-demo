variable "aws_region" {
  description = "Region the state bucket lives in."
  type        = string
  default     = "us-east-2"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like us-east-2."
  }
}

variable "project" {
  description = "Project name. Must match project in terraform/root.hcl, since the CI role names start with it."
  type        = string
  default     = "migdemo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase letters, digits and dashes, 2 to 21 characters."
  }
}

variable "owner" {
  description = "Owner tag value."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0 && !strcontains(var.owner, "REPLACE-ME")
    error_message = "Set owner to a real value."
  }
}

variable "expected_account_id" {
  description = "Optional pin. AWS account the bucket must live in. When set, the plan fails if the credentials are for another account."
  type        = string
  default     = null

  validation {
    condition     = var.expected_account_id == null || can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must be a 12 digit AWS account ID."
  }
}

variable "bucket_name" {
  description = "State bucket name. Same value as TF_STATE_BUCKET and state_bucket_name in terraform/bootstrap."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3 to 63 lowercase letters, digits, dots, dashes)."
  }

  validation {
    condition     = !strcontains(lower(var.bucket_name), "replace-me")
    error_message = "bucket_name still has the REPLACE-ME placeholder. Set the real bucket name."
  }
}

variable "import_existing_bucket" {
  description = "Import an existing bucket (one made by hand) instead of creating it. scripts/bootstrap.sh sets this on the first run."
  type        = bool
  default     = false
}

variable "use_kms" {
  description = "Default bucket encryption with a customer managed KMS key (true) or SSE-S3 (false)."
  type        = bool
  default     = true
}

variable "kms_deletion_window_days" {
  description = "Wait before KMS deletes the key after it is scheduled for deletion."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be 7 to 30."
  }
}

variable "noncurrent_version_days" {
  description = "Days before an old state version is deleted."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_days >= 1
    error_message = "noncurrent_version_days must be at least 1."
  }
}

variable "noncurrent_versions_to_keep" {
  description = "Old versions per object kept past noncurrent_version_days, so a rarely changed state file keeps some history."
  type        = number
  default     = 10

  validation {
    condition     = var.noncurrent_versions_to_keep >= 1 && var.noncurrent_versions_to_keep <= 100
    error_message = "noncurrent_versions_to_keep must be 1 to 100."
  }
}

variable "abort_multipart_days" {
  description = "Days before an unfinished multipart upload is cleaned up."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_multipart_days >= 1
    error_message = "abort_multipart_days must be at least 1."
  }
}

variable "require_tls_1_2" {
  description = "Deny requests that use TLS older than 1.2."
  type        = bool
  default     = true
}

variable "deny_ci_bucket_admin" {
  description = "Deny the GitHub CI roles changes to bucket settings and deletes of old object versions."
  type        = bool
  default     = true
}
