# SCP text. Each one starts from the AWS example noted above it:
#   https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_examples.html
#   https://github.com/aws-samples/service-control-policy-examples
# Actions and condition keys checked against the Service Authorization
# Reference (docs.aws.amazon.com/service-authorization/latest/reference/).
# jsonencode keeps them minified. SCPs max out at 5,120 characters:
#   https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html
# The tests check every size.
locals {
  regions = distinct(concat(var.allowed_regions, var.dr_copy_enabled ? [var.dr_region] : []))

  # aws:PrincipalArn for a role is the role ARN, not the session ARN.
  break_glass_arns = [for r in var.break_glass_role_names : "arn:aws:iam::*:role/${r}"]
  break_glass_condition = length(local.break_glass_arns) > 0 ? {
    ArnNotLike = { "aws:PrincipalArn" = local.break_glass_arns }
  } : {}

  # From Region-controls/Deny-access-to-AWS-based-on-the-requested-AWS-region.json.
  # These are global services, or calls that only go to us-east-1, so they
  # stay open in every region. kms:* is in the AWS list but left out here:
  # KMS is regional and every key this repo makes is in an allowed region,
  # so keys elsewhere stay blocked.
  global_actions = [
    "a4b:*", "acm:*", "aws-marketplace-management:*", "aws-marketplace:*",
    "aws-portal:*", "budgets:*", "ce:*", "chime:*", "cloudfront:*", "config:*",
    "cur:*", "directconnect:*", "ec2:DescribeRegions",
    "ec2:DescribeTransitGateways", "ec2:DescribeVpnGateways", "fms:*",
    "globalaccelerator:*", "health:*", "iam:*", "importexport:*",
    "mobileanalytics:*", "networkmanager:*", "organizations:*", "pricing:*",
    "route53:*", "route53domains:*", "route53-recovery-cluster:*",
    "route53-recovery-control-config:*", "route53-recovery-readiness:*",
    "s3:GetAccountPublic*", "s3:ListAllMyBuckets",
    "s3:ListMultiRegionAccessPoints", "s3:PutAccountPublic*", "shield:*",
    "sts:*", "support:*", "trustedadvisor:*", "waf-regional:*", "waf:*",
    "wafv2:*", "wellarchitected:*",
  ]

  scps = {
    # Privileged-access-controls/Deny-member-accounts-from-leaving-your-AWS-organization.json
    deny-leave-org = {
      description = "Member accounts can't leave the organization."
      statements = [{
        Sid      = "DenyLeaveOrg"
        Effect   = "Deny"
        Action   = ["organizations:LeaveOrganization"]
        Resource = "*"
      }]
    }

    region-lock = {
      description = "Deny calls outside the allowed regions, except global services."
      statements = [{
        Sid       = "DenyOtherRegions"
        Effect    = "Deny"
        NotAction = local.global_actions
        Resource  = "*"
        Condition = merge(
          { StringNotEquals = { "aws:RequestedRegion" = local.regions } },
          local.break_glass_condition,
        )
      }]
    }

    # Picked from the Deny-changes-to-security-services examples: only the
    # calls that turn a service off, delete it, or cut it from its admin.
    protect-security-services = {
      description = "Deny turning off CloudTrail, GuardDuty, Config, Access Analyzer and Security Hub."
      statements = [merge({
        Sid    = "DenySecurityServicesOff"
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging", "cloudtrail:DeleteTrail",
          "cloudtrail:UpdateTrail", "cloudtrail:PutEventSelectors",
          "guardduty:DeleteDetector", "guardduty:UpdateDetector",
          "guardduty:DisassociateFromAdministratorAccount",
          "guardduty:DisassociateFromMasterAccount",
          "guardduty:StopMonitoringMembers",
          "config:StopConfigurationRecorder",
          "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel",
          "access-analyzer:DeleteAnalyzer",
          "securityhub:DisableSecurityHub", "securityhub:BatchDisableStandards",
          "securityhub:DisassociateFromAdministratorAccount",
          "securityhub:DisassociateFromMasterAccount",
        ]
        Resource = "*"
      }, length(local.break_glass_condition) > 0 ? { Condition = local.break_glass_condition } : {})]
    }

    # From Privileged-access-controls/Deny-critical-IAM-user-actions.json,
    # cut to the two calls that make long lived credentials. People sign in
    # with Identity Center or aws login, CI with GitHub OIDC.
    deny-iam-users = {
      description = "Deny creating IAM users and access keys."
      statements = [merge({
        Sid      = "DenyIamUsersAndKeys"
        Effect   = "Deny"
        Action   = ["iam:CreateUser", "iam:CreateAccessKey"]
        Resource = "*"
      }, length(local.break_glass_condition) > 0 ? { Condition = local.break_glass_condition } : {})]
    }

    # Privileged-access-controls/Deny-the-root-user-from-performing-actions-except-S3-bucketpolicy-changes.json
    # The bucket policy calls stay open so root can fix a bucket policy that
    # locks everyone else out.
    deny-root-user = {
      description = "Deny the root user in member accounts, except bucket policy repair."
      statements = [{
        Sid       = "DenyRootUser"
        Effect    = "Deny"
        NotAction = ["s3:GetBucketPolicy", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy"]
        Resource  = "*"
        Condition = { ArnLike = { "aws:PrincipalArn" = "arn:aws:iam::*:root" } }
      }]
    }
  }

  scp_json = { for k, v in local.scps : k => jsonencode({ Version = "2012-10-17", Statement = v.statements }) }
}
