variable "name_prefix" {
  description = "Prefix for every name, e.g. migdemo-testing."
  type        = string
}

variable "max_receive_count" {
  description = "Receives before a message moves to the DLQ. Each failed attempt is one receive."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "SQS accepts a maxReceiveCount between 1 and 1000."
  }
}

variable "visibility_timeout_seconds" {
  description = "How long a received message stays hidden. Keep it above the slowest payment call plus its retries."
  type        = number
  default     = 60
}

variable "message_retention_seconds" {
  description = "How long the main queue keeps a message. The DLQ always keeps 14 days."
  type        = number
  default     = 345600 # 4 days, the SQS default
}
