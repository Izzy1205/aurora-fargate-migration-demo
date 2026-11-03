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

variable "ticket_rate_limit" {
  description = "Requests one IP may send to /ssn/tickets (issue and refresh) in 1 minute before it gets a 429."
  type        = number
  default     = 10

  validation {
    condition     = var.ticket_rate_limit >= 10 && var.ticket_rate_limit <= 2000000000
    error_message = "WAF accepts a rate limit between 10 and 2,000,000,000."
  }
}

variable "count_only" {
  description = "Count matches instead of blocking them, for a first rollout. Nothing is blocked while this is true."
  type        = bool
  default     = false
}

variable "geo_allow_countries" {
  description = "ISO 3166-1 alpha-2 country codes the WAF lets through; everything else is blocked (or counted with count_only). Empty turns the rule off."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.geo_allow_countries : can(regex("^[A-Z]{2}$", c))])
    error_message = "Use two-letter upper case ISO country codes, such as US."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the WAF log group."
  type        = number
  default     = 7
}
