# 0001. One AWS account per env

Status: accepted. Step 1 of 3 is in (the account map). No accounts moved yet.

## Context

testing, stage and production all live in one AWS account today. What
keeps them apart is IAM: each env's CI roles carry denies on the other
envs' secrets, state paths, SSN keys and ECS clusters. That works, but
it's a lot of policy to keep right, and an account admin or a bad policy
edit reaches all three envs at once. Quotas, budgets and the bill are
shared too.

AWS's own guidance is to split workloads and envs into separate accounts
under one Organization, with the account as the hard boundary:
https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/organizing-your-aws-environment.html

## Decision

Each env gets its own member account under my Organizations management
account. The management account only holds the org, billing and (later)
SCPs. No workloads in it.

Done in three PRs:

1. Account map (this one). Scripts and root.hcl learn which account each
   env is in and which AWS profile signs in to it. Nothing moves. All
   three envs still map to the one account.
2. SCPs as code, applied in the org root. Guardrails like region lock and
   no leaving the org.
   https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
3. Promotion across accounts. Copy the image by digest from the source
   account's ECR to the target's, with a repository policy on the source.
   https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-policy-examples.html

### The account map

`terraform/accounts.hcl`, copied from `terraform/accounts.hcl.example`.
Gitignored, same as the tfvars, since the repo is public and the account
ID and bucket name have been kept out of it so far. Account IDs aren't
secret, so committing them would also work. Keeping them out matches what
the repo already does.

```hcl
locals {
  testing_account_id  = "111111111111"
  testing_aws_profile = "migdemo-testing"
  # same for stage and production
}
```

One file, read two ways:

- `scripts/lib.sh` (`env_account`, `env_profile`, `use_env`), so
  bootstrap.sh, teardown.sh and reencrypt-state.sh.
- `terraform/root.hcl`, which adds `allowed_account_ids` to the generated
  provider when the env has an account set. Nothing in it touches
  remote_state.

Lookup per env: `MIGDEMO_<ENV>_ACCOUNT_ID`, then `<env>_account_id` in
accounts.hcl, then the old single pin (`MIGDEMO_ACCOUNT_ID` or
`expected_account_id` in the state-bucket tfvars). With none of the new
values set, the scripts act like before.

Region stays in `environments/<env>/env.hcl`.

CI doesn't read the map. Each GitHub environment's role ARN already names
the account, and `TF_STATE_BUCKET` can be set per GitHub environment when
the buckets split.

### Scripts

- Each env is checked against its own account. A mismatch says which env,
  which account it wants, which one you're on, and what profile to set.
- `<env>_aws_profile` (or `MIGDEMO_<ENV>_AWS_PROFILE`) makes the script
  set `AWS_PROFILE` for that env. A profile set up for Identity Center
  signs in with `aws sso login`, anything else with `aws login`.
  https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html
- `all` switches profile per env. If the envs are in more than one
  account and any of them has no profile, it stops before planning
  anything. One session can't reach two accounts, and guessing is worse
  than stopping.
- bootstrap: an env in testing's account still has to set
  `create_github_oidc_provider = false`. An env in its own account has to
  leave it true, since each account needs its own GitHub OIDC provider.
  https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html
- `bootstrap.sh state-bucket <env>`: for an env in its own account, reads
  `terraform/state-bucket/<env>.tfvars` and makes that account's bucket and
  key. For testing, or an env in testing's account, it's the same one
  bucket as before.
- teardown: each env's state bucket is `TF_STATE_BUCKET` if set, else
  `state_bucket_name` in that env's bootstrap tfvars.

### State

Nothing moves. Every env keeps its state in the current bucket under the
same keys, and the rendered backend is the same (scripts/tests/backend-render.sh
checks all 12 units against what main rendered).

New accounts get a fresh bucket each. Name it
`<owner>-migdemo-tfstate-<env>-<year>` so it's clear which account it's in.
The KMS alias stays `alias/migdemo-tfstate` in every account, since an
alias resolves in the caller's account. Each env's state is fresh in its
new account: deploy it from scratch, don't copy state across.

## Consequences

- Blast radius is one account. A leaked or broken role can't reach
  another env, whatever its policy says.
- Some cross-env denies become redundant once each env is alone in its
  account. Leave them until every env has moved:
  - peer secrets and peer SSN key aliases (`deny_peer_envs`): nothing to
    match in a single env account.
  - peer state paths (`deny_other_state`): redundant once each account has
    its own bucket. Not while two envs still share one.
  - ECS outside the env's cluster (`deny_services_outside_cluster`): still
    useful against non migdemo services, keep it.
  - `deny_state_key_outside_s3` and the SSN vault denies are within one
    env, they stay.
- Promotion has to cross accounts (PR 3). Today it copies inside one
  registry.
- More to sign in to. Identity Center profiles per account cover it.
- Budgets become per account, which is more useful than one shared one.

## Migration steps

1. Create the accounts in Organizations, one per env, from the
   management account.
   https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_create.html
2. Identity Center: a permission set with admin, assigned to me in each
   account. `aws configure sso` once per account, profiles named like
   `migdemo-testing`.
3. Tear down the env being moved with `scripts/teardown.sh <env>`, then
   `scripts/bootstrap.sh destroy <env>`. Do stage and production first,
   testing last (or leave testing where it is).
4. Fill in `terraform/accounts.hcl` for that env: account ID and profile.
5. `cp terraform/state-bucket/terraform.tfvars.example
   terraform/state-bucket/<env>.tfvars`, set `expected_account_id` and a
   new `bucket_name`, then `scripts/bootstrap.sh state-bucket <env>`.
6. In `terraform/bootstrap/<env>.tfvars`: `state_bucket_name` to the new
   bucket, `create_github_oidc_provider = true`. Then
   `scripts/bootstrap.sh <env>`. It writes the new role ARNs to the
   GitHub environments.
7. Set `TF_STATE_BUCKET` on that env's GitHub environments to the new
   bucket.
8. Deploy the env fresh (deploy.yml for testing, promote.yml for the
   others, after PR 3).

## Cost

Accounts are free. The real cost is per account things that were shared:
one state bucket and KMS key each (a KMS key is about $1 a month), and
per account GuardDuty or Config if those get turned on. The env stacks
already have their own network, so that part costs the same.
Roughly the same bill as now plus a few dollars a month.
