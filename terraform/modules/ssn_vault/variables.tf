variable "name_prefix" {
  description = "Prefix for every resource name, project-environment."
  type        = string
}

variable "db_cluster_resource_id" {
  description = "Aurora cluster resource ID. The vault login may only connect to this cluster."
  type        = string
}

variable "vault_db_username" {
  description = "Postgres login for the token service. Created by db-logins.sql, signs in with IAM auth, no password."
  type        = string
  default     = "ssn_vault_login"
}

variable "secret_recovery_window_days" {
  description = "Days a deleted pepper secret can be restored. 0 deletes at once (demo teardown)."
  type        = number
  default     = 0
}

variable "vault_task_role_arn" {
  description = "Vault task role ARN. The only principal the key policy lets encrypt and decrypt SSN data. Pass the role's arn attribute so the role exists before the key policy names it."
  type        = string
}
