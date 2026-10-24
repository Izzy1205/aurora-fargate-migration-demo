# Bootstrap stack: the CI identities. Applied once from Izzy's own machine
# with his own admin credentials, never from the pipeline. Keeping it apart
# means the pipeline's terraform role cannot widen its own permissions.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform-bootstrap"
    }
  }
}

module "github_oidc" {
  source = "../modules/github_oidc"

  name_prefix          = "${var.project}-${var.environment}"
  aws_region           = var.aws_region
  github_repo          = var.github_repo
  infra_environment    = var.github_infra_environment
  app_environment      = var.github_app_environment
  create_oidc_provider = var.create_github_oidc_provider
  state_bucket_name    = var.state_bucket_name
  state_key            = var.state_key
}

output "plan_role_arn" {
  description = "GitHub variable AWS_PLAN_ROLE_ARN."
  value       = module.github_oidc.plan_role_arn
}

output "terraform_role_arn" {
  description = "GitHub variable AWS_TERRAFORM_ROLE_ARN."
  value       = module.github_oidc.terraform_role_arn
}

output "deploy_role_arn" {
  description = "GitHub variable AWS_DEPLOY_ROLE_ARN."
  value       = module.github_oidc.deploy_role_arn
}
