variable "name_prefix" {
  description = "Prefix for every name, e.g. migdemo-testing."
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB the web ACL is attached to."
  type        = string
}

variable "rate_limit" {
  description = "Requests one IP may send in 5 minutes before the rate rule acts on it."
  type        = number
  default     = 1000

  validation {
    condition     = var.rate_limit >= 10 && var.rate_limit <= 2000000000
    error_message = "WAF accepts a rate limit between 10 and 2,000,000,000."
  }
}

variable "reveal_rate_limit" {
  description = "Requests one IP may send to /ssn/reveal in 1 minute before it gets a 429."
  type        = number
  default     = 10

  validation {
    condition     = var.reveal_rate_limit >= 10 && var.reveal_rate_limit <= 2000000000
    error_message = "WAF accepts a rate limit between 10 and 2,000,000,000."
  }
}

variable "count_only" {
  description = "Count matches instead of blocking them, for a first rollout. Nothing is blocked while this is true."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch retention for the WAF log group."
  type        = number
  default     = 7
}
