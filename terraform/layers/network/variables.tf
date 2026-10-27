variable "project" {
  description = "Short project name, used as a name prefix and a tag."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "Use 3 to 21 lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "Environment name, used as a name prefix and a tag."
  type        = string
}

# Only read by the provider.tf that Terragrunt generates, which tflint does
# not see when it lints this folder on its own.
# tflint-ignore: terraform_unused_declarations
variable "owner" {
  description = "Owner tag value. Terragrunt sets it from MIGDEMO_OWNER."
  type        = string
}

variable "app_port" {
  description = "Port the app container listens on."
  type        = number
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the load balancer on port 80. Use your own IP as a /32. Terragrunt sets it from MIGDEMO_ALB_INGRESS_CIDRS."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
}

variable "single_az_endpoints" {
  description = "Put interface endpoints in one AZ only. Halves endpoint cost; fine for a demo, not for production."
  type        = bool
}
