variable "name_prefix" {
  description = "Prefix for repository names."
  type        = string
}

variable "repositories" {
  description = "Repository short names."
  type        = list(string)
  default     = ["app", "migrate"]
}

variable "images_to_keep" {
  description = "How many images each repo keeps."
  type        = number
  default     = 10
}

variable "pull_principals" {
  description = "IAM principal ARNs allowed to pull images (cross-account promote). Empty means no repository policy, same-account IAM only."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.pull_principals : can(regex("^arn:aws:iam::[0-9]{12}:(root|role/.+)$", a))
    ])
    error_message = "pull_principals must be IAM root or role ARNs."
  }
}
