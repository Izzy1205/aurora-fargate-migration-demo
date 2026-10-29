# Terragrunt generates the default provider (the home region) in
# provider.tf at run time, see terraform/root.hcl. This file adds the
# second region, where the backup copies live. It sits here, not in
# root.hcl, because only this layer needs it, and committed so plain
# terraform validate on this folder sees it too.
#
# Same default tags as the generated provider, so the copies and their
# key are tagged like everything else.
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
    }
  }
}
