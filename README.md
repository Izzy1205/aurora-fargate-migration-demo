# aurora-fargate-migration-demo

## Contents

- [What it is](#what-it-is)
- [How to set everything up and tear it all down](#how-to-set-everything-up-and-tear-it-all-down)
- [Planned additional work / gaps](#planned-additional-work--gaps)

### Glossary

| Term | Meaning |
| --- | --- |
| testing / stage / production | The three envs. Only testing builds images. |
| promote | Copy an image by digest up the chain: testing to stage, stage to production. |
| bootstrap | `scripts/bootstrap.sh`. CI roles, state bucket, org OU. Hand run only. |
| teardown | `scripts/teardown.sh`. Destroys an env's four Terragrunt layers. Hand run only. |
| accounts.hcl | Gitignored map of which AWS account and profile each env uses. |
| migdemo OU | Org OU with the demo SCPs. Accounts only move in when listed. |

## What it is

A small payments-style web app on AWS the way I'd want to run it for
real: ECS Fargate, Aurora PostgreSQL, three environments, and security
checks in the pipeline. Fargate over EKS on purpose. For a small team
that's fewer things to patch and prove secure.

What runs:

- App on Fargate behind an ALB, WAF in front (common attacks, proxies,
  geo, rate limit). HTTPS on 443; port 80 only 301s to HTTPS. Default
  cert is self-signed in ACM. Set `domain_name` and `route53_zone_id` in
  env.hcl for a public ACM cert.
- Aurora PostgreSQL, writer plus reader in different AZs. App and Flyway
  each have their own login in Secrets Manager. Master stays with RDS.
- Daily AWS Backup, 7 day keep. Copy to us-west-2 is built but off
  (`dr_copy_enabled`); an org SCP blocks that region today.
- SQS for payment requests, with a dead letter queue.
- CloudWatch alarms and a dashboard, including an availability SLO and
  backup failure email.
- SSN vault: the app never stores a raw SSN. Tokenize, tickets, and
  reveal live in a separate task with its own KMS key and DB login.
  Details in `app/src/demo_app/ssn/` and `terraform/modules/ssn_vault`.

How it ships:

- Terraform plus Terragrunt in four layers: network, data, app,
  observability. PRs plan and scan. Merge to main deploys testing.
  Plans that delete or replace something stop for a person, except the
  yearly self-signed TLS renew.
- Only testing builds images. Stage and production get the same bytes
  through `promote.yml`, by digest. A commit moves up only if it's on
  main and is what the env below is running. Stage is started by hand.
  Production is started by hand or a `vX.Y.Z` tag, never by a merge, and
  every production plan, apply and release waits for a reviewer.

Accounts (M1):

- All three envs still share one AWS account today. IAM keeps them apart.
- `terraform/accounts.hcl` (from the `.example`) maps each env to an
  account and profile. Scripts and `root.hcl` read it. Nothing has moved
  yet. See [docs/adr/0001-account-per-env.md](docs/adr/0001-account-per-env.md).
- `terraform/org` defines a `migdemo` OU and five SCPs (no leave org,
  region lock, security services stay on, no IAM users or keys, no root
  user). Applied with `scripts/bootstrap.sh org` from the management
  account. Testing can sit in that OU; stage and production in their own
  accounts is parked for later. Steps in
  [terraform/org/README.md](terraform/org/README.md).
- Promote is hardened for a later split: resolve reads the source account,
  the copy logs into both registry URIs and keeps the digest. Same-account
  is still the live path. Cross-account needs `promote_from_account_id`
  and source `pull_principals` when an env moves; both default empty.

## How to set everything up and tear it all down

Tools the scripts check in `scripts/lib.sh`: AWS CLI v2 (2.32+),
Terraform 1.17+, Terragrunt 1.2.1+, `gh` 2.55+, jq 1.6+, openssl, git,
bash. Sign in with `aws login` (or SSO for Identity Center profiles) and
`gh auth login`. You need admin on the repo and on the AWS account.

### Set up

One command per step, from the repo root.

1. Copy each `terraform/bootstrap/*.tfvars.example` to the name without
   `.example` and replace every `REPLACE-ME`. Stage and production must
   set everything testing sets.
2. Optional account map: `cp terraform/accounts.hcl.example
   terraform/accounts.hcl` and fill it in. Skip while every env shares
   one account.
3. `./scripts/bootstrap.sh state-bucket`
   First run writes the state-bucket tfvars if missing, adopts or creates
   the bucket, then moves that root's state into it. Never destroyed by
   these scripts.
4. Create the GitHub environments by hand for each env you'll run:
   `<env>-infra-plan`, `<env>-infra`, `<env>-app`. The script sets
   variables on them; it does not create them.
5. `./scripts/bootstrap.sh all`
   Or one env: `./scripts/bootstrap.sh testing`, then `stage`, then
   `production`. Testing first (it makes the GitHub OIDC provider the
   others reuse while they share the account). Sets the three role ARN
   variables and reads them back. `--dry-run` plans only.
   `--no-github` prints the `gh` commands instead of writing them.
6. Optional org guardrails, from the management account:
   `cp terraform/org/terraform.tfvars.example terraform/org/terraform.tfvars`
   then `./scripts/bootstrap.sh org --dry-run`, then
   `./scripts/bootstrap.sh org`. Leave `ou_account_ids` empty until you
   mean to move an account. Checklist in
   [terraform/org/README.md](terraform/org/README.md).
7. Repo variables: `TF_STATE_BUCKET`, `AWS_REGION`, `OWNER`,
   `BUDGET_EMAIL`, `ALB_INGRESS_CIDRS` (your IP as a /32).
8. Deploy: merge to main for testing. Then run `promote.yml` to stage,
   then to production. After the first deploy of each env, set that
   env's SSN pepper once (not a CI role) and confirm the alarm email:
   `aws secretsmanager put-secret-value --secret-id <name_prefix>/ssn/hmac-pepper --secret-string "$(openssl rand -hex 32)"`

State uses SSE-KMS (`alias/migdemo-tfstate`) unless you turn that off.
`scripts/reencrypt-state.sh` can rewrite older SSE-S3 objects. Provider
lock files: after a provider bump, `scripts/lock-providers.sh` and commit
the locks.

### Tear down

Teardown is manual so CI never deletes the stack.

```bash
./scripts/teardown.sh testing --dry-run
./scripts/teardown.sh testing
```

Same for `stage`, `production`, or `all` (production, then stage, then
testing; skips empty envs). One run: preflight, destroy plans, typed
confirm, apply saved plans (observability, app, data, network), leftover
check. Before data it stops active AWS Backup jobs on the env's vaults
and waits. Logs go under `logs/`.

Teardown never touches bootstrap or the state bucket. To retire an env:

```bash
./scripts/teardown.sh <env>
./scripts/bootstrap.sh destroy <env>
```

`destroy` refuses while the env still has tagged resources, and refuses
testing while stage or production still have a bootstrap.

Tearing down testing while stage or production is up (or stage while
production is up) strands promote: images and backups for that source go
away.

## Planned additional work / gaps

In and live for M1: account map, org OU plus SCPs, promote ready for a
later cross-account copy. Still on one shared account. Stage and
production in their own accounts is parked; when that happens, follow the
migration steps in the ADR, set `promote_from_account_id`, and put the
target deploy role on the source env's `pull_principals`.

Not built yet:

- Verified identity for the SSN actor (ALB OIDC or Cognito), and real
  step-up re-auth for ticket refresh. Today those are headers.
- Prove the calling service (mTLS or similar) instead of trusting
  `X-Caller`. App to vault is plain HTTP on 8080 inside the VPC.
- Hashed tickets, a shared rate limit store, ticket cleanup, key
  rotation re-encrypt, two-person approval for bulk reveal.
- Claimant sign-up and the wage loader calling tokenize for real.
- Scan images again at promote (today it copies the digest Trivy already
  scanned in testing).
- Extend `stale-stack.yml` past testing.
- Pin first-party GitHub actions to commit SHAs where they still use tags.
- DR backup copy to us-west-2 once the blocking SCP and `dr_copy_enabled`
  both allow it.
