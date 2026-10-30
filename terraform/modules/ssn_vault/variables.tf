variable "name_prefix" {
  description = "Prefix for every resource name, project-environment."
  type        = string
}

variable "secret_recovery_window_days" {
  description = "Days a deleted pepper secret can be restored. 0 deletes at once (demo teardown)."
  type        = number
  default     = 0
}
