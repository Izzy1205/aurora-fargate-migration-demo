aurora-fargate-migration-demo

1) What I set out to do

I wanted to build a small payments-style web app on AWS the way I'd
want to run it for real: a real database, three environments, and
security checks in the pipeline instead of bolted on later. I picked
ECS Fargate over EKS on purpose. For a small team it's fewer things
to patch, upgrade, and prove secure.

2) What this repo does
- Runs the app in containers on ECS Fargate behind a load balancer
- Puts a WAF in front to block common attacks and rate limit by IP
- Serves plain HTTP, locked to one IP. HTTPS needs a domain for an ACM
  cert, and the demo doesn't have one. In prod it's a 443 listener with
  80 redirecting to it.
- Stores data in Aurora PostgreSQL. The app and Flyway each log in as
  their own role with a password in Secrets Manager. The app can only
  read and write rows; Flyway owns the schema. The master password stays
  with RDS for break-glass and is never given to the app or Flyway.
  Each environment runs a writer and a reader in different AZs. If the
  writer fails, Aurora promotes the reader, usually in under 60 seconds.
  With no reader it has to rebuild the writer, usually in under 10
  minutes. One line in env.hcl (`aurora_instance_count`) sets how many.
- Backs up Aurora every day with AWS Backup and keeps 7 days. Copying
  each backup to a second region (us-west-2) is built but off
  (`dr_copy_enabled`), because this AWS org's SCP only allows full use
  of us-east-2. Turning it on is a policy change, not a code change.
- Holds a paid family and medical leave data model in the schema (V6 to
  V9): claimants, employers, wages, claims, leave, benefit weeks,
  payments, documents, and an audit trail. SSNs are only a token plus a
  keyed hash, and the database refuses a second payment for the same
  claim and week. Payments and audit rows are add-only for the app login.
  The token service that fills them in is described in section 8.
- Sends payment requests through an SQS queue with a dead letter queue
- Watches it all with 22 CloudWatch alarms and a dashboard, including an
  availability SLO with burn rate alerts and a p95 latency alarm. It also
  emails if a backup job fails.

3) How it all works
Everything is Terraform, organized with Terragrunt into four layers:
network, data, app, and observability. Every pull request runs a plan
plus security scans. Merging to main deploys to testing on its own. If
a plan would delete or replace something, the pipeline stops and a
person has to handle it. Stage and production are set up in code but
not deployed yet. Production will always be a manual deploy with a
reviewer.

4) What you need to run it
- An AWS account and the AWS CLI signed in
- Terraform 1.17.0 and Terragrunt 1.2.1
- Apply `terraform/bootstrap` once (state bucket and GitHub OIDC roles)
- Repo variables: `TF_STATE_BUCKET`, `AWS_REGION`, `OWNER`,
  `BUDGET_EMAIL`, `ALB_INGRESS_CIDRS` (your IP as a /32)
- GitHub environments: `testing-infra-plan`, `testing-infra`, `testing-app`
- Confirm the SNS alarm email after the first deploy
- Budget about $3 a day while it's running

5) How it tears down
Teardown is manual on purpose so the pipeline can never delete things
on its own. Sign in to AWS first, since an expired session partway
through leaves a mess. Then run `./scripts/teardown.sh testing`,
check each plan, and type yes. It deletes the backups too. The bootstrap stays until you remove it yourself.

6) How I built this
I designed it, ran it, and debugged it myself, and I used an AI
assistant along the way to check facts and review changes.

7) Bringing your own app
The platform doesn't care what the app is. To run something else on it,
you mostly need:
- A container image that listens on one port and has a health check path
- Your database migrations, packaged as their own image (the pipeline
  runs them as a one-off task before deploying)
- Any settings the app needs, as environment variables, with secrets
  kept in Secrets Manager instead of in code

The network, database, WAF, queue, alarms, and pipeline stay the same.

8) SSN token service
The database holds the ticket, the vault holds the coat. The app never
keeps an SSN. `claimant` only ever has `ssn_token` (a random `tok_...`
value) and `ssn_hmac` (a keyed hash, so duplicate checks and wage matching
are a plain equals). The real number lives in `ssn_vault` (V10), encrypted
with its own KMS key. Tickets are permanent identifiers on claimant rows.
They don't expire, and the same SSN always gets the same ticket.

The pieces:
- `ssn_vault` table: the token, the HMAC, the KMS ciphertext and the ARN
  of the key that made it. Only the `ssn_vault_rw` group can touch it,
  and only to read and add rows. `app_user` has no grant on it, and the
  db-logins task takes the broad grant back on every deploy.
- KMS key, `alias/<name_prefix>-ssn` (for example
  `alias/migdemo-testing-ssn`). Every call carries the encryption context
  `{purpose: ssn, token: <token>}`, so a blob copied onto another row
  won't decrypt.
- HMAC pepper, a Secrets Manager secret at
  `<name_prefix>/ssn/hmac-pepper`, encrypted with the same key. It keys
  the blind lookup hash. Terraform makes the secret but never its value.
- Audit trail: every reveal writes an `audit_event` row (`ssn.reveal`,
  who, why, which token, never the SSN) in the same transaction as the
  read and the decrypt. No audit row, no SSN.

Endpoints:
- `POST /ssn/tokenize` takes `{"ssn": "..."}` and returns the token and
  HMAC. 201 the first time, 200 after that.
- `POST /ssn/reveal` takes `{"token": "...", "reason": "..."}`, with the
  actor from `X-Actor` for now. 401 with no actor, 400 with no reason,
  404 for a token that is malformed or unknown.
- Both answer 503 `ssn service unavailable` if anything below is missing
  or failing, and never echo input. Responses are `no-store`.

How the app finds its key, pepper and login:
Nothing comes from the task definition. The first `/ssn` request works it
out with the task role and caches it (a failure is retried after 30
seconds):
1. The environment name prefix comes from the ECS task metadata endpoint,
   which Fargate gives every container. The app task family is
   `<name_prefix>-app`, so the app drops the `-app`. `SSN_NAME_PREFIX`
   overrides it for local runs.
2. KMS `DescribeKey` on the alias gives the key ARN.
3. Secrets Manager `GetSecretValue` reads the pepper.
4. The database login is `ssn_vault_login`, a member of `ssn_vault_rw`.
   It has no password. Each connection signs in with a 15 minute IAM auth
   token the app makes locally from its task role.

Grants:
- IAM, on the app task role (`terraform/modules/ssn_vault`): KMS Encrypt
  and Decrypt on the SSN key only with `purpose=ssn`; DescribeKey on that
  key; GetSecretValue on the pepper secret only, plus Decrypt on the key
  only through Secrets Manager; `rds-db:connect` as `ssn_vault_login` on
  this cluster only.
- Database (`db/logins/db-logins.sql`): `ssn_vault_login` can log in, has
  `rds_iam`, and is in `ssn_vault_rw`. `ssn_vault_rw` gets SELECT and
  INSERT on `ssn_vault` and INSERT on `audit_event`. No UPDATE or DELETE.

Why it's built this way:
The pipeline fails any plan that deletes or replaces a resource. Changing
a task definition's environment variables or secrets makes Terraform
replace it, so adding the key ARN or the pepper there stops the deploy.
That happened once. Reading the key by its alias and the pepper by its
name, and using IAM auth for the login, means this change only adds IAM
statements and SQL. The task definitions stay as they are.

Turning it on in an environment:
1. Merge and let the deploy run. It adds the IAM statements and the login.
2. Set the pepper once, out of band, as 64 hex characters (32 random
   bytes). Never change it afterwards: a new pepper breaks every
   `ssn_hmac` match.
3. The next `/ssn` request picks it up within 30 seconds.

Threat model, short version:
- A leaked app login or a SQL injection in the main app can't read
  `ssn_vault`: `app_user` has no grant on it.
- A copied database dump has ciphertext only. It needs the KMS key, and
  the key only works with `purpose=ssn` in the encryption context.
- The HMAC is keyed, so the nine-digit space can't be brute forced
  without the pepper secret.
- The vault login has no password to leak. Signing in needs the task role.
- Every reveal is attributable and has a reason. Logs never carry the
  SSN, the token or the actor, and mask anything shaped like an SSN.

Code: `app/src/demo_app/ssn/` (`config.py` is the startup lookup). Key,
pepper secret and IAM: `terraform/modules/ssn_vault`.

Not done yet:
- Actor from the verified identity (ALB OIDC or Cognito) and a "may
  reveal" role check, instead of a header.
- The token service runs inside the app task and uses its role. Its own
  task and role would keep the key away from the rest of the app.
- Rate limiting on reveal, two-person approval for bulk reveal.
- A key rotation re-encrypt job (rows record their key ARN).
- Claimant sign-up and the wage loader calling tokenize.
