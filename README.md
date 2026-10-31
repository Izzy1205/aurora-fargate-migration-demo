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
- Watches it all with 24 CloudWatch alarms and a dashboard, including an
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
with its own KMS key. The `tok_` value is a permanent identifier on the
claimant row, and the same SSN always gets the same one. It can't reveal
anything. Reading the number takes a reveal ticket (`rtk_...`, V11), which
is short-lived and works once.

Reveal tickets:
- Staff ask for a ticket for one claimant and one of their claims. The
  claim must be open: `submitted`, `in_review` or `approved` (an approved
  claim is still paying out). `denied` and `withdrawn` are closed.
- A ticket dies at the first of: 72 hours after it was issued, its claim
  closing, being used once, or being replaced by a refresh. The 72 hour cap
  is also a CHECK on the table, so no code path can store a longer one.
- Every time check uses the database clock, `now()`, not the app's.
- Reveal marks the ticket used, writes the audit row and decrypts in one
  transaction. If the audit insert or the decrypt fails, it all rolls back:
  no SSN, and the ticket isn't burned.
- Refresh is its own endpoint and needs a fresh sign-in (see below). Only
  the person the ticket was issued to can refresh it. An expired ticket that
  was never used can be refreshed; a used or replaced one can't, and
  neither can one whose claim has closed. The old ticket is revoked and
  points at its replacement, and the new one gets its own 72 hours.
- Any rejected ticket (unknown, malformed, expired, used, replaced, claim
  closed, someone else's) gets the same 404, so the answer doesn't tell a
  caller which tickets exist. The log records only the category.
- Audit rows point at a ticket by its id, never its value. `app_user` can
  read `audit_event`, and the value is a bearer credential while it lives.

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
- `ssn_ticket` table: the ticket, which vault row and claim it's for, who
  it was issued to, when it was issued, expires, was used or revoked, and
  what replaced it. Only `ssn_vault_rw` can touch it. It can read and add
  rows, and can only change `used_at`, `revoked_at` and `replaced_by`. No
  foreign keys, same as `ssn_vault`, so the claim retention purge isn't
  blocked by a login that can't delete tickets.
- Audit trail: three actions, one row each, always who and why, never the
  SSN or a ticket value. `ssn.ticket_issue` and `ssn.ticket_refresh`
  (`record_type` `ssn_ticket`) and `ssn.reveal` (`record_type`
  `ssn_vault`, with the ticket id and claim id). Each is written in the
  same transaction as the change it records. No audit row, no change.

Endpoints:
- `POST /ssn/tokenize` takes `{"ssn": "..."}` and returns the token and
  HMAC. 201 the first time, 200 after that.
- `POST /ssn/tickets` takes `{"ssn_token": "...", "claim_id": 1,
  "reason": "..."}` and returns `{ticket, claim_id, expires_at}` with 201.
  401 with no actor, 400 with no reason, 404 when that token has no open
  claim with that id.
- `POST /ssn/reveal` takes `{"ticket": "...", "reason": "..."}` and
  returns `{ssn_token, claim_id, ssn}` with 200. 401 with no actor, 400
  with no reason, 404 for any ticket that isn't valid right now. It no
  longer takes `{"token": ...}`; that body gets a 422.
- `POST /ssn/tickets/refresh` takes `{"ticket": "...", "reason": "..."}`
  and returns a new ticket with 201. 401 with no actor, 400 with no
  reason, 401 `re-authentication required` without a fresh sign-in, 404
  for a ticket that can't be refreshed.
- The actor comes from `X-Actor` for now.
- Re-auth is a placeholder: `X-Reauth-Actor` must match the actor and
  `X-Reauth-At` (Unix seconds) must be under 5 minutes old. Anyone who can
  set `X-Actor` can set these too, so it only shows where the check goes.
  The real one is an identity provider step-up (OIDC `max_age` and
  `auth_time`) behind the same `ReauthVerifier` interface in
  `ssn/reauth.py`.
- The WAF allows 10 reveals per minute from one IP and answers 429 after
  that (`reveal_rate_limit` in `terraform/modules/waf`, rule
  `rate-limit-ssn-reveal`, paths starting with `/ssn/reveal`). The ticket
  endpoints get their own 10 per minute per IP (`ticket_rate_limit`, rule
  `rate-limit-ssn-tickets`, paths starting with `/ssn/tickets`, which
  covers issue and refresh). They slow a script walking tickets; the
  actor, reason and audit row are still the real gate.
- All of them answer 503 `ssn service unavailable` if anything below is missing
  or failing, and never echo input. Responses are `no-store`.

Where it runs:
The app's `/ssn` routes only forward to the private SSN vault service
(`demo_app.vault`, `terraform/modules/ssn_vault_service`, reachable only
from the app tasks at `ssn-vault.<name_prefix>.internal:8080`). If the
vault can't be reached, times out or answers 5xx, the app answers 503 and
logs a WARN `ssn_vault_unavailable` line (also a CloudWatch metric in
`MigDemo/SsnVault`). The app has no SSN code: it never loads the token
service, KMS, the pepper or the vault login, and its task role denies all
three.

Vault alarms (`terraform/modules/observability/alarms.tf`, sent to the
same SNS topic as the rest):
- `<name_prefix>-ssn-vault-unavailable`: at least one
  `ssn_vault_unavailable` in 5 minutes (`MigDemo/SsnVault`, dimension
  `NamePrefix`). The app answered 503 on `/ssn` because it couldn't use
  the vault.
- `<name_prefix>-ssn-vault-tasks-low`: the `<name_prefix>-ssn-vault`
  service has had no live tasks for 3 minutes.

First checks when either fires:
1. Is the vault service running tasks? ECS console, or
   `aws ecs describe-services --cluster <name_prefix>-cluster --services <name_prefix>-ssn-vault`.
   Stopped tasks show why they stopped.
2. The vault log, `/ecs/<name_prefix>/ssn-vault`. It names the step that
   failed. The app's WARN line has a `reason` (`dns`, `connect_error`,
   `connect_timeout`, `read_timeout`, `bad_response`, `vault_5xx` or
   `no_vault_url`).
3. The vault security group still allows 8080 from the app security group.
4. Cloud Map: `ssn-vault.<name_prefix>.internal` has a healthy instance
   for each running task.

How the vault finds its key, pepper and login:
Nothing comes from the task definition. The first `/ssn` request works it
out with the vault task role and caches it (a failure is retried after 30
seconds):
1. The environment name prefix comes from the ECS task metadata endpoint,
   which Fargate gives every container. The vault task family is
   `<name_prefix>-ssn-vault`, so it drops the `-ssn-vault`.
   `SSN_NAME_PREFIX` overrides it for local runs.
2. KMS `DescribeKey` on the alias gives the key ARN.
3. Secrets Manager `GetSecretValue` reads the pepper.
4. The database login is `ssn_vault_login`, a member of `ssn_vault_rw`.
   It has no password. Each connection signs in with a 15 minute IAM auth
   token the vault makes locally from its task role.

Grants:
- IAM, on the vault task role (`terraform/modules/ssn_vault`): KMS Encrypt
  and Decrypt on the SSN key only with `purpose=ssn`; DescribeKey on that
  key; GetSecretValue on the pepper secret only, plus Decrypt on the key
  only through Secrets Manager; `rds-db:connect` as `ssn_vault_login` on
  this cluster only.
- IAM, on the app task role (inline policy `ssn-vault`): explicit Deny on
  the SSN key (Encrypt, Decrypt, ReEncrypt, DescribeKey, GenerateDataKey),
  on GetSecretValue under `<name_prefix>/ssn/`, and on `rds-db:connect` as
  `ssn_vault_login`.
- Database (`db/logins/db-logins.sql`): `ssn_vault_login` can log in, has
  `rds_iam`, and is in `ssn_vault_rw`. `ssn_vault_rw` gets SELECT and
  INSERT on `ssn_vault` and INSERT on `audit_event`. On `ssn_ticket` it
  gets SELECT, INSERT, and UPDATE of `used_at`, `revoked_at` and
  `replaced_by` only. To check a claim is open it can read `claim (id,
  claimant_id, status)` and `claimant (id, ssn_token)`, no other columns.
  No DELETE anywhere. The same grants are in V11, `afterMigrate.sql` and
  `db-logins.sql`, and `app_user` loses its broad grant on `ssn_ticket`.
- Permissions boundary (`terraform/modules/github_oidc/boundary.tf`, applied
  with bootstrap): every role the stack creates has this ceiling, so a
  role's grants only work if the boundary allows them too. The workload
  boundary (app and other roles) allows none of the SSN key, the pepper or
  the vault login.
- Vault boundary (same file, `<name_prefix>-ssn-vault-boundary`): the
  ceiling for the token service's own roles once it moves out of the app
  task. Only roles named `<name_prefix>-ssn-vault-*` may carry it. It has
  the same SSN statements (pepper secret by exact name), image pull and the
  `/ecs/<name_prefix>/ssn-vault` log group, and nothing else. The app no
  longer calls KMS itself, so a separate bootstrap change takes the SSN
  statements out of the workload boundary.
- Network: the VPC has no NAT, so KMS needs its own interface endpoint
  (`kms` in `interface_endpoints`). Secrets Manager already had one.

Why it's built this way:
The pipeline fails any plan that deletes or replaces a resource. Changing
a task definition's environment variables or secrets makes Terraform
replace it, so adding the key ARN or the pepper there stops the deploy.
That happened once. Reading the key by its alias and the pepper by its
name, and using IAM auth for the login, means this change only adds IAM
statements and SQL. The task definitions stay as they are.

Turning it on in an environment:
1. Apply `terraform/bootstrap` so the vault boundary has the SSN statements.
   CI never applies bootstrap.
2. Merge and let the deploy run. It adds the KMS endpoint, the IAM
   statements and the login.
3. Set the pepper once, out of band, as 64 hex characters (32 random
   bytes). Never change it afterwards: a new pepper breaks every
   `ssn_hmac` match.
   `aws secretsmanager put-secret-value --secret-id <name_prefix>/ssn/hmac-pepper --secret-string "$(openssl rand -hex 32)"`
4. The next `/ssn` request picks it up within 30 seconds. Check it with a
   fake SSN in the 9xx range (never a real one):
   `curl -X POST "$ALB/ssn/tokenize" -H "Content-Type: application/json" -d '{"ssn":"900-12-3456"}'`

If it answers 503, the vault log (`/ecs/<name_prefix>/ssn-vault`) names
the step that failed and nothing else, for example
`KMS key lookup failed (AccessDeniedException)`. AWS calls give up after
a 3 second connect or 5 second read, with one retry, so a missing route shows up as a quick 503 instead of a load balancer
504. Bringing it up in testing hit both: a 504 from the missing KMS
endpoint, then AccessDenied from the boundary. The two fixes are above.

Try the ticket flow in testing:
A ticket needs a claimant with an open claim, and nothing in the app
makes those yet. `POST /demo/seed-claim` fills that gap in testing only.
It takes the exact JSON `/ssn/tokenize` returns (`ssn_token` and
`ssn_hmac`), needs `X-Actor`, and makes one fake employer, a fake claimant
for that token and one `submitted` claim, then returns `claim_id`. 201 the
first time, 200 with the same ids after that. It writes one
`demo.seed_claim` audit row when it adds something.
- It only answers when the environment name prefix ends in `-testing`. On
  ECS that comes from the task family in the task metadata, and
  `SSN_NAME_PREFIX` is ignored there, so no env var can turn it on in
  stage or production. If the prefix can't be read, it's off. Off means
  the same 404 as a path that doesn't exist, for every method and body.
- It uses the app's own login (`app_user`), which already owns those
  tables. `ssn_vault_login` gets no new grants, and nothing in Terraform
  or the task definition changed.
- Code: `app/src/demo_app/demo_seed.py`.

In Git Bash, fake SSN only, all within 5 minutes for the refresh step
(the re-auth headers must be under 5 minutes old):

```bash
ALB=http://<your-alb-dns-name>
J="Content-Type: application/json"
TOK=$(curl -s -X POST "$ALB/ssn/tokenize" -H "$J" -d '{"ssn":"900-12-3456"}'); echo "$TOK"
SEED=$(curl -s -X POST "$ALB/demo/seed-claim" -H "$J" -H "X-Actor: izzy" -d "$TOK"); echo "$SEED"
TOKEN=$(echo "$TOK" | sed -E 's/.*"ssn_token":"([^"]+)".*/\1/')
CLAIM=$(echo "$SEED" | sed -E 's/.*"claim_id":([0-9]+).*/\1/')
issue() { curl -s -X POST "$ALB/ssn/tickets" -H "$J" -H "X-Actor: izzy" -d "{\"ssn_token\":\"$TOKEN\",\"claim_id\":$CLAIM,\"reason\":\"demo\"}" | sed -E 's/.*"ticket":"([^"]+)".*/\1/'; }
reveal() { curl -s -w " %{http_code}\n" -X POST "$ALB/ssn/reveal" -H "$J" -H "X-Actor: izzy" -d "{\"ticket\":\"$1\",\"reason\":\"demo\"}"; }
T1=$(issue); echo "$T1"
reveal "$T1"    # 200 with the SSN
reveal "$T1"    # 404, the ticket is burned
T2=$(issue); echo "$T2"
NEW=$(curl -s -X POST "$ALB/ssn/tickets/refresh" -H "$J" -H "X-Actor: izzy" -H "X-Reauth-Actor: izzy" -H "X-Reauth-At: $(date +%s)" -d "{\"ticket\":\"$T2\",\"reason\":\"demo\"}"); echo "$NEW"
T3=$(echo "$NEW" | sed -E 's/.*"ticket":"([^"]+)".*/\1/')
reveal "$T2"    # 404, replaced by the refresh
reveal "$T3"    # 200 with the SSN
```

Refresh works on a ticket that hasn't been used, so the flow issues a
second ticket for it. A used ticket can't be refreshed. `X-Reauth-At` is
Unix seconds from `date +%s`, and `X-Reauth-Actor` must match `X-Actor`.

Threat model, short version:
- A leaked app login or a SQL injection in the main app can't read
  `ssn_vault`: `app_user` has no grant on it.
- A copied database dump has ciphertext only. It needs the KMS key, and
  the key only works with `purpose=ssn` in the encryption context.
- The HMAC is keyed, so the nine-digit space can't be brute forced
  without the pepper secret.
- The vault login has no password to leak. Signing in needs the task role.
- Every reveal is attributable and has a reason. Logs never carry the
  SSN, the token, a ticket or the actor, and mask anything shaped like an
  SSN.
- A leaked `tok_` value reveals nothing. A leaked ticket works once, for
  at most 72 hours, and only while its claim is open.

Code: `app/src/demo_app/ssn/` (`config.py` is the startup lookup). Key,
pepper secret and IAM: `terraform/modules/ssn_vault`.

Not done yet:
- Actor from the verified identity (ALB OIDC or Cognito) and a "may
  reveal" role check, instead of a header.
- A per-actor reveal limit in the app, and two-person approval for bulk
  reveal. The WAF only limits by IP.
- A key rotation re-encrypt job (rows record their key ARN).
- Real re-auth for refresh (identity provider step-up), replacing the
  header placeholder.
- Store a hash of the ticket instead of the value, and maybe require the
  same actor at reveal as at issue.
- A job that deletes tickets that are long dead.
- Claimant sign-up and the wage loader calling tokenize.
