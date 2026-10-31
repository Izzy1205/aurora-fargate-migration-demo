variable "name_prefix" {
  description = "Prefix for every resource name, project-environment."
  type        = string
}

variable "vpc_id" {
  description = "VPC the service and its DNS namespace live in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the vault tasks. No public IP."
  type        = list(string)
}

variable "cluster_arn" {
  description = "ECS cluster the service runs in. The app's cluster."
  type        = string
}

variable "app_security_group_id" {
  description = "App task security group. The only group allowed to call the vault."
  type        = string
}

variable "endpoints_security_group_id" {
  description = "Security group on the VPC interface endpoints."
  type        = string
}

variable "db_security_group_id" {
  description = "Aurora security group."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "The vault boundary from terraform/bootstrap. Both roles carry it."
  type        = string
}

variable "task_policy_json" {
  description = "Task role policy: SSN key, pepper and vault DB login. From modules/ssn_vault."
  type        = string
}

variable "image" {
  description = "App image for the first task definition only. CI registers new revisions pinned by digest."
  type        = string
}

variable "repository_arn" {
  description = "App ECR repository. The execution role may pull from it only."
  type        = string
}

variable "db_host" {
  description = "Aurora writer endpoint."
  type        = string
}

variable "db_port" {
  description = "Aurora port."
  type        = number
}

variable "db_name" {
  description = "Database name."
  type        = string
}

variable "port" {
  description = "Port the vault container listens on."
  type        = number
  default     = 8080
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 7
}
