variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
}

variable "app_port" {
  description = "Port the app container listens on."
  type        = number
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on port 80."
  type        = list(string)
}

variable "single_az_endpoints" {
  description = "Place interface endpoints in the first private subnet only."
  type        = bool
}

variable "interface_endpoints" {
  description = "Interface endpoint service suffixes. These replace a NAT gateway for Fargate. kms is for the SSN token service (DescribeKey, Encrypt, Decrypt)."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "secretsmanager", "logs", "sqs", "kms"]
}

variable "flow_log_retention_days" {
  description = "Retention for the VPC flow log group."
  type        = number
  default     = 7
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for every IAM role this module creates."
  type        = string
}
