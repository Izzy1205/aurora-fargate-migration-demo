# terraform test with a mocked AWS provider. No AWS calls.
#   cd terraform/org && terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_organizations_organization" {
    override_during = plan
    defaults = {
      master_account_id = "111111111111"
      roots = [{
        id           = "r-test"
        arn          = "arn:aws:organizations::111111111111:root/o-test/r-test"
        name         = "Root"
        policy_types = [{ type = "SERVICE_CONTROL_POLICY", status = "ENABLED" }]
      }]
      accounts = [
        { id = "111111111111", arn = "", email = "", name = "mgmt", status = "ACTIVE", state = "ACTIVE", joined_method = "", joined_timestamp = "" },
        { id = "222222222222", arn = "", email = "", name = "demo", status = "ACTIVE", state = "ACTIVE", joined_method = "", joined_timestamp = "" },
      ]
    }
  }
  mock_resource "aws_organizations_organizational_unit" {
    override_during = plan
    defaults        = { id = "ou-test-demo" }
  }
}

variables {
  management_account_id = "111111111111"
  owner                 = "ci"
}

run "defaults" {
  command = plan

  assert {
    condition     = toset(keys(aws_organizations_policy.scp)) == toset(["deny-leave-org", "region-lock", "protect-security-services", "deny-iam-users", "deny-root-user"])
    error_message = "Expected the five SCPs."
  }

  assert {
    condition     = alltrue([for p in aws_organizations_policy.scp : p.type == "SERVICE_CONTROL_POLICY"])
    error_message = "Every policy must be an SCP."
  }

  assert {
    condition     = alltrue([for k, j in local.scp_json : length(j) <= 5120])
    error_message = "An SCP is over 5,120 characters."
  }

  assert {
    condition     = aws_organizations_organizational_unit.demo.parent_id == "r-test" && aws_organizations_organizational_unit.demo.name == "migdemo"
    error_message = "The OU must be new, named migdemo, under the root."
  }

  # Only the new OU gets attachments. Nothing on the root or on an
  # existing OU or account.
  assert {
    condition     = alltrue([for a in aws_organizations_policy_attachment.ou : a.target_id == "ou-test-demo"])
    error_message = "SCPs must attach to the new OU only."
  }

  assert {
    condition     = length(var.ou_account_ids) == 0 && length(output.ou_account_ids) == 0
    error_message = "No account moves by default."
  }

  assert {
    condition     = jsondecode(local.scp_json["region-lock"]).Statement[0].Condition.StringNotEquals["aws:RequestedRegion"] == ["us-east-2"]
    error_message = "The region lock must allow only us-east-2 by default."
  }

  assert {
    condition = alltrue([for a in ["iam:*", "sts:*", "organizations:*", "support:*", "cloudfront:*", "wafv2:*", "route53:*", "budgets:*"] :
    contains(jsondecode(local.scp_json["region-lock"]).Statement[0].NotAction, a)])
    error_message = "The region lock must leave the global services open."
  }

  assert {
    condition     = !contains(jsondecode(local.scp_json["region-lock"]).Statement[0].NotAction, "kms:*")
    error_message = "KMS is regional and must stay under the region lock."
  }

  assert {
    condition     = !can(jsondecode(local.scp_json["region-lock"]).Statement[0].Condition.ArnNotLike)
    error_message = "No break glass exception unless one is set."
  }

  assert {
    condition     = jsondecode(local.scp_json["deny-leave-org"]).Statement[0].Action == ["organizations:LeaveOrganization"]
    error_message = "deny-leave-org must deny LeaveOrganization."
  }

  assert {
    condition     = toset(jsondecode(local.scp_json["deny-iam-users"]).Statement[0].Action) == toset(["iam:CreateUser", "iam:CreateAccessKey"])
    error_message = "deny-iam-users must deny CreateUser and CreateAccessKey."
  }

  assert {
    condition     = jsondecode(local.scp_json["deny-root-user"]).Statement[0].Condition.ArnLike["aws:PrincipalArn"] == "arn:aws:iam::*:root"
    error_message = "deny-root-user must match the root user ARN."
  }

  assert {
    condition = alltrue([for a in ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "guardduty:DeleteDetector", "config:StopConfigurationRecorder", "access-analyzer:DeleteAnalyzer", "securityhub:DisableSecurityHub"] :
    contains(jsondecode(local.scp_json["protect-security-services"]).Statement[0].Action, a)])
    error_message = "protect-security-services must deny turning each service off."
  }
}

run "dr_region_and_break_glass" {
  command = plan

  variables {
    dr_copy_enabled        = true
    break_glass_role_names = ["BreakGlass"]
  }

  assert {
    condition     = jsondecode(local.scp_json["region-lock"]).Statement[0].Condition.StringNotEquals["aws:RequestedRegion"] == ["us-east-2", "us-west-2"]
    error_message = "dr_copy_enabled must add us-west-2."
  }

  assert {
    condition     = jsondecode(local.scp_json["region-lock"]).Statement[0].Condition.ArnNotLike["aws:PrincipalArn"] == ["arn:aws:iam::*:role/BreakGlass"]
    error_message = "The break glass role must skip the region lock."
  }

  assert {
    condition     = jsondecode(local.scp_json["deny-iam-users"]).Statement[0].Condition.ArnNotLike["aws:PrincipalArn"] == ["arn:aws:iam::*:role/BreakGlass"]
    error_message = "The break glass role must skip the IAM user deny."
  }

  assert {
    condition     = !can(jsondecode(local.scp_json["deny-root-user"]).Statement[0].Condition.ArnNotLike)
    error_message = "The root user deny has no exception."
  }
}

run "account_list_checked" {
  command = plan

  variables {
    ou_account_ids = ["333333333333"]
  }

  expect_failures = [aws_organizations_organizational_unit.demo]
}

run "management_not_allowed_in_ou" {
  command = plan

  variables {
    ou_account_ids = ["111111111111"]
  }

  expect_failures = [var.ou_account_ids]
}

run "wrong_management_account" {
  command = plan

  variables {
    management_account_id = "222222222222"
  }

  expect_failures = [aws_organizations_organizational_unit.demo]
}

run "scps_disabled" {
  command = plan

  override_data {
    target = data.aws_organizations_organization.this
    values = {
      master_account_id = "111111111111"
      roots             = [{ id = "r-test", arn = "", name = "Root", policy_types = [] }]
      accounts          = []
    }
  }

  expect_failures = [aws_organizations_organizational_unit.demo]
}
