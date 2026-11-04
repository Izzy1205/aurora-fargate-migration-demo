# terraform/org

The demo OU and its SCPs. Applied by hand from the management account with
`scripts/bootstrap.sh org`. CI never runs it. Background and the reasons are
in [docs/adr/0001-account-per-env.md](../../docs/adr/0001-account-per-env.md).

## What it makes

All new, nothing adopted or imported:

- one OU, `migdemo`, under the org root
- five SCPs, attached to that OU only
- nothing on the root, on an OU that's already there, or on any account

So the first apply changes what no account can do. An account only gets
these SCPs once it's in `ou_account_ids` and the script has moved it in.
That's opt in because moving an account changes which SCPs apply to it:
it keeps the root's SCPs and its own, and swaps its old parent OU's SCPs
for this OU's. An account sitting right under the root loses nothing.

| SCP | Size | Denies |
| --- | --- | --- |
| `migdemo-deny-leave-org` | 137 | `organizations:LeaveOrganization` |
| `migdemo-region-lock` | 889 (901 with the DR region) | every call outside `allowed_regions` (plus `dr_region` when `dr_copy_enabled`), except global services |
| `migdemo-protect-security-services` | 699 | turning off or deleting CloudTrail trails, GuardDuty detectors, Config recorders and delivery channels, Access Analyzer analyzers, Security Hub, and cutting GuardDuty or Security Hub from its admin |
| `migdemo-deny-iam-users` | 149 | `iam:CreateUser`, `iam:CreateAccessKey` |
| `migdemo-deny-root-user` | 239 | everything by the member account root user, except the three bucket policy calls |

Sizes are characters with no break glass roles. The limit is 5,120.
`terraform output policy_sizes` shows the real numbers.

Sources:
- examples: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_examples.html
  and https://github.com/aws-samples/service-control-policy-examples
- actions and keys: https://docs.aws.amazon.com/service-authorization/latest/reference/reference_policies_actions-resources-contextkeys.html
- `aws:RequestedRegion`, `aws:PrincipalArn`: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html
- size and count limits: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html

SCPs don't apply to the management account or to service linked roles:
https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html

## Region lock notes

- The global list is the AWS example list minus `kms:*`. KMS is regional
  and every key here is in us-east-2, so keys in other regions stay
  blocked.
- `iam`, `sts`, `organizations`, `support`, `cloudfront`, `waf`, `wafv2`,
  `route53`, `budgets`, `ce`, `health` and `acm` stay open. GitHub OIDC is
  `sts:AssumeRoleWithWebIdentity`, so it's open too.
- The demo's WAF is `REGIONAL` on the ALB in us-east-2. No CloudFront.
- Backup copies to us-west-2 (`dr_copy_enabled`) are off in every env.hcl.
  An existing SCP already blocks us-west-2. Turning DR on needs
  `dr_copy_enabled = true` here and that other SCP changed too, since any
  deny wins.
- The AWS CLI signs S3 and other calls for the profile's region. A profile
  whose region isn't us-east-2 gets denied, so check it (step 9 below).

## What could break, and how it was checked

- Root user deny: if the session the scripts use in the testing account
  is that account's root user (`aws login` with root), every bootstrap and
  teardown call is denied after the move. Step 8 checks this. Use an
  Identity Center role or an IAM role instead.
- IAM user deny: nothing in this repo makes IAM users or keys (no
  `aws_iam_user` or `aws_iam_access_key`). An existing IAM user's keys
  keep working, but new keys can't be made.
- Security service deny: the repo makes none of these and teardown deletes
  none.
- CI roles, bootstrap, teardown, Aurora, ECS, ALB, WAF, Backup, KMS, ECR:
  all in us-east-2, so the region lock leaves them alone.
- Existing SCPs: the plan only creates. The tests check that every
  attachment targets the new OU.

## State

Local, in `terraform/org/terraform.tfstate` (gitignored). The only state
bucket is in the testing member account, where the CI roles have
`s3:Get*` and the state deny only covers `bootstrap*` keys. Local state is
out of their reach. It holds IDs and policy text, no secrets. Keep a copy.
If it's lost, import again:

    terraform import aws_organizations_organizational_unit.demo <ou id>
    terraform import 'aws_organizations_policy.scp["region-lock"]' <policy id>
    terraform import 'aws_organizations_policy_attachment.ou["region-lock"]' <ou id>:<policy id>

## Run it

Use your management account profile in place of `<mgmt>` and the testing
account's profile in place of `<testing>`. One command per step.

Check first:

1. `aws sts get-caller-identity --profile <mgmt>`: Account is the management account.
2. `aws organizations describe-organization --profile <mgmt>`: MasterAccountId is the same.
3. `aws organizations list-roots --profile <mgmt>`: PolicyTypes has SERVICE_CONTROL_POLICY ENABLED. Note the root id.
4. `aws organizations list-policies --filter SERVICE_CONTROL_POLICY --profile <mgmt>`: write down what's there (FullAWSAccess and the one that blocks us-west-2). Nothing named `migdemo-*`.
5. `aws organizations list-targets-for-policy --policy-id <id> --profile <mgmt>`: once per policy from step 4, to see where each one is attached.
6. `aws organizations list-organizational-units-for-parent --parent-id <root id> --profile <mgmt>`: no OU named `migdemo` yet.
7. `aws organizations list-parents --child-id <testing account id> --profile <mgmt>`: where testing sits now.
8. `aws sts get-caller-identity --profile <testing>`: the Arn must not end in `:root`.
9. `aws configure get region --profile <testing>`: must be us-east-2.

Apply:

10. `cp terraform/org/terraform.tfvars.example terraform/org/terraform.tfvars`, then fill it in. Leave `ou_account_ids = []`.
11. `./scripts/bootstrap.sh org --dry-run`: 11 to add (1 OU, 5 policies, 5 attachments), 0 to change, 0 to destroy.
12. `./scripts/bootstrap.sh org`: type `org` to apply.
13. `aws organizations list-policies-for-target --target-id <ou id> --filter SERVICE_CONTROL_POLICY --profile <mgmt>`: FullAWSAccess plus the five.

Move testing in, when ready:

14. Add the testing account to `ou_account_ids` in terraform.tfvars.
15. `./scripts/bootstrap.sh org --dry-run`: no resource changes, one output change (`ou_account_ids`). It lists each account it would move and where it is now.
16. `./scripts/bootstrap.sh org`: type `org` to save the new list to state, then it shows the account's current parent and its SCPs and asks you to type `move`. An account already in the OU is skipped.
17. `./scripts/bootstrap.sh all --dry-run` (as `<testing>`): should plan no changes.
18. Run the PR workflow once, or push a docs change, to see a CI plan pass.

Undo a move: `aws organizations move-account --account-id <id> --source-parent-id <ou id> --destination-parent-id <old parent> --profile <mgmt>`.
