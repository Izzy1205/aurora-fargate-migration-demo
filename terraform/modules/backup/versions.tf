# aws.dr is the second region. The caller passes it in, so this module
# never decides on its own where the copies go.
terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.dr]
    }
  }
}
