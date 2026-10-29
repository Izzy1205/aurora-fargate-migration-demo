# Shared by every unit. Per-env values live in environments/<env>/env.hcl.

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  project     = "migdemo"
  environment = local.env.environment
  aws_region  = local.env.aws_region

  unit_path = trimprefix(replace(path_relative_to_include(), "\\", "/"), "environments/")
}

# S3 native locking, no DynamoDB. disable_bucket_update keeps Terragrunt off the bucket settings.
remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket       = local.env.state_bucket
    key          = "aurora-fargate-migration-demo/${local.unit_path}/terraform.tfstate"
    region       = get_env("TF_STATE_REGION", local.aws_region)
    encrypt      = true
    use_lockfile = true

    disable_bucket_update = true
  }
}

# Owner comes from MIGDEMO_OWNER so it stays out of the repo.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOT
    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = {
          Project     = "${local.project}"
          Environment = "${local.environment}"
          Owner       = var.owner
          ManagedBy   = "terraform"
        }
      }
    }
  EOT
}

# MIGDEMO_* instead of TF_VAR_*, since strict mode errors on undeclared TF_VAR_s.
inputs = {
  project     = local.project
  environment = local.environment
  owner       = get_env("MIGDEMO_OWNER")
}
