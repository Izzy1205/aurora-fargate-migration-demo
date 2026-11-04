# Organizations is a global service. The region only sets the endpoint the
# provider signs for.
provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project   = var.project
      Owner     = var.owner
      ManagedBy = "terraform/org"
    }
  }
}
