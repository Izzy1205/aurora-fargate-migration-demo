# Shared by every unit under environments/. Each unit's terragrunt.hcl
# includes this file and one file from environments/_envcommon.
#
# What lives here: remote state, the generated provider, and the inputs every
# layer takes. Per-environment values live in environments/<env>/env.hcl.

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  project     = "migdemo"
  environment = local.env.environment
  aws_region  = local.env.aws_region

  # testing/network, testing/data, testing/app and so on.
  unit_path = trimprefix(replace(path_relative_to_include(), "\\", "/"), "environments/")

  # State key. TF_STATE_KMS_KEY wins when it's set, and set but empty means
  # no key. Otherwise follow use_kms in the state-bucket tfvars, same as
  # scripts/lib.sh, and default to the key when that file isn't there (CI).
  # try() covers a missing file (HCL evaluates both sides of a ?:) and one
  # that won't parse. Both fall back to the key.
  sb_tfvars   = "${dirname(find_in_parent_folders("root.hcl"))}/state-bucket/terraform.tfvars"
  sb_use_kms  = try(jsondecode(read_tfvars_file(local.sb_tfvars)).use_kms, true)
  kms_env     = get_env("TF_STATE_KMS_KEY", "unset")
  kms_default = local.sb_use_kms ? "alias/${local.project}-tfstate" : ""
  kms_key_id  = local.kms_env == "unset" ? local.kms_default : local.kms_env
}

# One state object per unit:
#   aurora-fargate-migration-demo/<env>/<unit>/terraform.tfstate
# S3 native locking puts a .tflock next to each one, so there is no DynamoDB
# table. The bucket is never created or changed from here: it already exists,
# and disable_bucket_update stops Terragrunt from touching its settings.
#
# kms_key_id makes the backend send SSE-KMS with the state bucket's key on
# both the state and the .tflock. Without it the backend sends AES256 and
# the bucket default key never applies. The alias is the one
# terraform/state-bucket makes. An alias name resolves in the caller's
# account, so no account ID is needed here. With no key (use_kms = false
# or TF_STATE_KMS_KEY="") kms_key_id is left out, not set to "": the
# backend rejects "" as an invalid key ID, and with no kms_key_id and
# encrypt = true it sends AES256 (SSE-S3).
#   https://developer.hashicorp.com/terraform/language/backend/s3#kms_key_id
#   https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html
remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = merge(
    {
      bucket       = local.env.state_bucket
      key          = "aurora-fargate-migration-demo/${local.unit_path}/terraform.tfstate"
      region       = get_env("TF_STATE_REGION", local.aws_region)
      encrypt      = true
      use_lockfile = true

      disable_bucket_update = true
    },
    local.kms_key_id == "" ? {} : { kms_key_id = local.kms_key_id },
  )
}

# Same provider and tags the flat stack had. Owner comes from MIGDEMO_OWNER
# (see inputs below) so it stays out of the repo, like before.
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

# Values that stay out of the repo are read from MIGDEMO_* environment
# variables instead of TF_VAR_*. Terragrunt's strict input check treats a
# TF_VAR_ that a unit doesn't declare as an error, and not every unit needs
# every value. get_env with no default fails loudly when one is missing.
inputs = {
  project     = local.project
  environment = local.environment
  owner       = get_env("MIGDEMO_OWNER")
}
