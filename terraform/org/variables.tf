variable "management_account_id" {
  description = "Management account of the organization. The provider refuses any other account. Lives in the gitignored terraform.tfvars, never in git."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12 digit AWS account ID."
  }
}

variable "aws_profile" {
  description = "AWS CLI profile signed in to the management account. scripts/bootstrap.sh org uses the same one. Null uses the default credentials."
  type        = string
  default     = null
}

variable "aws_region" {
  description = "Region the provider signs requests for."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Project name, used in the OU and policy names."
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

variable "allowed_regions" {
  description = "Regions member accounts in the OU can use."
  type        = list(string)
  default     = ["us-east-2"]

  validation {
    condition     = length(var.allowed_regions) > 0 && alltrue([for r in var.allowed_regions : can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", r))])
    error_message = "allowed_regions needs at least one region, each like us-east-2."
  }
}

variable "dr_copy_enabled" {
  description = "Also allow dr_region, for the Aurora backup copies (dr_copy_enabled in the env.hcl files). Another SCP that denies the region still wins."
  type        = bool
  default     = false
}

variable "dr_region" {
  description = "Region the backup copies go to. Same as dr_region in the env.hcl files."
  type        = string
  default     = "us-west-2"
}

variable "ou_account_ids" {
  description = "Member accounts to move into the OU. Empty by default, so no account changes OU until you add it here. scripts/bootstrap.sh org moves them after the apply, one confirm each. Moving an account changes which SCPs apply to it."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.ou_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "ou_account_ids must be 12 digit AWS account IDs."
  }

  validation {
    condition     = !contains(var.ou_account_ids, var.management_account_id)
    error_message = "The management account can't go in the OU. SCPs don't apply to it anyway."
  }
}

variable "break_glass_role_names" {
  description = "Role names in member accounts that skip the region lock, the IAM user deny and the security service deny. Empty means no exception. The root user deny has none."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.break_glass_role_names : can(regex("^[A-Za-z0-9+=,.@_*-]{1,64}$", r))])
    error_message = "break_glass_role_names must be IAM role names (a * wildcard is allowed)."
  }
}
