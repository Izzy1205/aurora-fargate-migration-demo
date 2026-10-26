# Terragrunt generates provider.tf and backend.tf next to these files at run
# time (see terraform/root.hcl). 1.11 is the first release where S3 native
# locking (use_lockfile) is generally available.
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
