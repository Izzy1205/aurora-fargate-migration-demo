terraform {
  # 1.9 to match terraform/bootstrap. Import blocks with for_each need 1.7+.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
