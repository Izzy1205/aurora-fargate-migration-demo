# Plan-only. Empty pull_principals: no repository policy (same-account path).
# Non-empty: one policy per repo with pull-only actions.
# Run: terraform init -backend=false && terraform test

provider "aws" {
  region                      = "us-east-2"
  access_key                  = "placeholder"
  secret_key                  = "placeholder"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

run "same_account_default" {
  command = plan

  variables {
    name_prefix = "migdemo-testing"
  }

  assert {
    condition     = length(aws_ecr_repository_policy.pull) == 0
    error_message = "Default must create no repository policy."
  }

  assert {
    condition     = length(aws_ecr_repository.this) == 2
    error_message = "Default repos are app and migrate."
  }
}

run "cross_account_pull" {
  command = plan

  variables {
    name_prefix     = "migdemo-testing"
    pull_principals = ["arn:aws:iam::222222222222:role/migdemo-stage-github-deploy"]
  }

  assert {
    condition     = length(aws_ecr_repository_policy.pull) == 2
    error_message = "Non-empty pull_principals must attach a policy to each repo."
  }

  assert {
    condition = alltrue([
      for p in values(aws_ecr_repository_policy.pull) :
      length(regexall("ecr:BatchGetImage", p.policy)) > 0 &&
      length(regexall("ecr:GetDownloadUrlForLayer", p.policy)) > 0 &&
      length(regexall("ecr:PutImage", p.policy)) == 0
    ])
    error_message = "Policy must be pull-only."
  }
}
