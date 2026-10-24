variable "name_prefix" {
  description = "Prefix for repository names."
  type        = string
}

variable "repositories" {
  description = "Repository short names."
  type        = list(string)
  default     = ["app", "migrate"]
}

variable "images_to_keep" {
  description = "How many images each repo keeps."
  type        = number
  default     = 10
}
