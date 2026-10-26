# The CI identities and the permissions boundary for the main stack's roles.
# Applied by hand with admin credentials, never from the pipeline, so the
# pipeline's terraform role can't widen its own permissions.

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

  name_prefix             = "${var.project}-${var.environment}"
  aws_region              = var.aws_region
  github_repo             = var.github_repo
  github_subject_prefixes = var.github_subject_prefixes
  plan_environment        = var.github_plan_environment
  infra_environment       = var.github_infra_environment
  app_environment         = var.github_app_environment
  create_oidc_provider    = var.create_github_oidc_provider
  state_bucket_name       = var.state_bucket_name
  state_key               = var.state_key
}

output "plan_role_arn" {
  description = "GitHub variable AWS_PLAN_ROLE_ARN."
  value       = module.github_oidc.plan_role_arn
}

output "terraform_role_arn" {
  description = "GitHub variable AWS_TERRAFORM_ROLE_ARN."
  value       = module.github_oidc.terraform_role_arn
}

output "workload_boundary_arn" {
  description = "Boundary on every role the main stack creates. The main stack builds this ARN itself."
  value       = module.github_oidc.workload_boundary_arn
}

output "deploy_role_arn" {
  description = "GitHub variable AWS_DEPLOY_ROLE_ARN."
  value       = module.github_oidc.deploy_role_arn
}
