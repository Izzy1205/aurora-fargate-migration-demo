variable "aws_region" {
  description = "AWS region for every resource in the demo."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project name, used as a name prefix and a tag."
  type        = string
  default     = "migdemo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "Use 3 to 21 lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "Environment name, used as a name prefix and a tag."
  type        = string
  default     = "demo"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "budget_email" {
  description = "Email address that receives the budget alerts."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD."
  type        = number
  default     = 10
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the load balancer on port 80. Use your own IP as a /32."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.40.0.0/16"
}

variable "single_az_endpoints" {
  description = "Put interface endpoints in one AZ only. Halves endpoint cost; fine for a demo, not for production."
  type        = bool
  default     = true
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL version. Scale to zero needs 16.3+ (or 15.7+, 14.12+, 13.15+)."
  type        = string
  default     = "16.6"
}

variable "aurora_min_capacity" {
  description = "Minimum ACUs. 0 lets the cluster pause when idle."
  type        = number
  default     = 0
}

variable "aurora_max_capacity" {
  description = "Maximum ACUs."
  type        = number
  default     = 2
}

variable "aurora_seconds_until_auto_pause" {
  description = "Idle seconds before the cluster pauses (300 to 86400)."
  type        = number
  default     = 300
}

variable "db_name" {
  description = "Database name."
  type        = string
  default     = "demo"
}

variable "app_image_tag" {
  description = "Image tag for the first task definitions. CI registers new revisions with the commit SHA."
  type        = string
  default     = "bootstrap"
}
