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

variable "alert_email" {
  description = "Where alarm emails go. Terragrunt sets it from MIGDEMO_BUDGET_EMAIL, the same address as the budget."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix. From the app unit."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "App target group ARN suffix. From the app unit."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name. From the app unit."
  type        = string
}

variable "ecs_service_name" {
  description = "App service name. From the app unit."
  type        = string
}

variable "app_desired_count" {
  description = "Tasks the service runs after a release. From the app unit."
  type        = number
}

variable "waf_web_acl_name" {
  description = "WAF web ACL name. From the app unit."
  type        = string
}

variable "payment_queue_name" {
  description = "Payment requests queue name. From the app unit."
  type        = string
}

variable "payment_dlq_name" {
  description = "Payment requests dead letter queue name. From the app unit."
  type        = string
}

variable "aurora_cluster_identifier" {
  description = "Aurora cluster identifier. From the data unit."
  type        = string
}

# Keys left out keep the module defaults (modules/observability/variables.tf).
# Terraform drops unknown keys without a word, so the validation catches typos.
variable "alarm_thresholds" {
  description = "Alarm threshold overrides, set per environment in env.hcl."
  type        = map(number)
  default     = {}

  validation {
    condition = alltrue([for k in keys(var.alarm_thresholds) : contains([
      "elb_5xx_count", "target_5xx_count", "ecs_cpu_percent", "ecs_memory_percent",
      "aurora_cpu_percent", "aurora_acu_percent", "aurora_freeable_memory_bytes", "aurora_connections",
      "aurora_replica_lag_ms", "waf_blocked_requests", "queue_oldest_message_seconds",
      "slo_availability_percent", "latency_p95_seconds",
    ], k)])
    error_message = "Unknown key in alarm_thresholds. See modules/observability/variables.tf for the list."
  }
}
