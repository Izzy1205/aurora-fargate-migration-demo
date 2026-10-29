variable "name_prefix" {
  description = "Prefix for every name, e.g. migdemo-testing."
  type        = string
}

variable "alert_email" {
  description = "Address subscribed to the alarm topic. AWS emails it a link that has to be clicked before anything is delivered."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (app/<name>/<id>), the LoadBalancer dimension."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix (targetgroup/<name>/<id>), the TargetGroup dimension."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name, the ClusterName dimension."
  type        = string
}

variable "ecs_service_name" {
  description = "ECS service name, the ServiceName dimension."
  type        = string
}

variable "desired_count" {
  description = "Tasks the service should be running. The task count and healthy host alarms fire below this."
  type        = number

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1, or the low task and healthy host alarms can never fire."
  }
}

variable "waf_web_acl_name" {
  description = "WAF web ACL name, the WebACL dimension."
  type        = string
}

variable "payment_queue_name" {
  description = "Payment requests queue name, the QueueName dimension."
  type        = string
}

variable "payment_dlq_name" {
  description = "Payment requests dead letter queue name."
  type        = string
}

variable "aurora_cluster_identifier" {
  description = "Aurora cluster identifier, the DBClusterIdentifier dimension."
  type        = string
}

# Defaults sized for testing.
variable "thresholds" {
  description = "Alarm thresholds. See the README monitoring section for what each one means."
  type = object({
    elb_5xx_count                = optional(number, 5)         # ALB's own 5xx in 5 minutes
    target_5xx_count             = optional(number, 5)         # app 5xx in 5 minutes
    ecs_cpu_percent              = optional(number, 80)        # service average
    ecs_memory_percent           = optional(number, 80)        # service average
    aurora_cpu_percent           = optional(number, 80)        # of the CPU at max ACU
    aurora_acu_percent           = optional(number, 90)        # of max ACU
    aurora_freeable_memory_bytes = optional(number, 268435456) # 256 MiB
    aurora_connections           = optional(number, 100)
    aurora_replica_lag_ms        = optional(number, 1000) # worst reader, milliseconds
    waf_blocked_requests         = optional(number, 100)  # blocked in 5 minutes
    queue_oldest_message_seconds = optional(number, 300)
    slo_availability_percent     = optional(number, 99.9) # good requests over 30 days
    latency_p95_seconds          = optional(number, 1)    # p95 app response time
  })
  default = {}

  # Under about 93% a 14.4x burn can never fire.
  validation {
    condition     = var.thresholds.slo_availability_percent >= 95 && var.thresholds.slo_availability_percent < 100
    error_message = "slo_availability_percent must be at least 95 and below 100."
  }

  validation {
    condition     = var.thresholds.latency_p95_seconds > 0
    error_message = "latency_p95_seconds must be above 0."
  }
}
