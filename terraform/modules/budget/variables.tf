variable "name_prefix" {
  description = "Prefix for the budget name."
  type        = string
}

variable "limit_usd" {
  description = "Monthly limit in USD."
  type        = number
}

variable "email" {
  description = "Alert recipient."
  type        = string
}
