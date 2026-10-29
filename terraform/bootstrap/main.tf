# Applied by hand with admin creds, never from CI, so CI can't widen its own permissions.

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
  state_key_prefix        = "${var.state_key_prefix}/${var.environment}"
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
  description = "Boundary on every role the Terragrunt units create. The network and app layers build this ARN themselves."
  value       = module.github_oidc.workload_boundary_arn
}

output "deploy_role_arn" {
  description = "GitHub variable AWS_DEPLOY_ROLE_ARN."
  value       = module.github_oidc.deploy_role_arn
}

output "backup_role_arn" {
  description = "Role AWS Backup runs as for the Aurora backups. The data layer finds it by name, nothing to copy anywhere."
  value       = module.github_oidc.backup_role_arn
}
