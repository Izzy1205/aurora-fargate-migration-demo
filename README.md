aurora-fargate-migration-demo

1) What I set out to do

I wanted to build a small payments-style web app on AWS the way I'd
want to run it for real: a real database, three environments, and
security checks in the pipeline instead of bolted on later. I picked
ECS Fargate over EKS on purpose. For a small team it's fewer things
to patch, upgrade, and prove secure.

2) What this repo does
- Runs the app in containers on ECS Fargate behind a load balancer
- Puts a WAF in front to block common attacks, anonymizing proxies and
  requests from outside the US, and to rate limit by IP. Every
  environment blocks. `waf_count_only = true` in env.hcl switches an
  environment to count only, for trying new rules; `waf_geo_allow_countries`
  sets the allowed countries (`[]` turns that rule off).
- Serves HTTPS on 443, locked to one IP, with TLS 1.3 and 1.2 only
  (`ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`). Port 80 only answers
  with a 301 to HTTPS. With no domain, the cert is self-signed and
  imported into ACM for free, so browsers warn and curl needs `-k`. Set
  `domain_name` and `route53_zone_id` in env.hcl to get a public ACM cert
  instead (see section 4).
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
- Watches it all with 29 CloudWatch alarms and a dashboard, including an
  availability SLO with burn rate alerts and a p95 latency alarm. It also
  emails if a backup job fails.

3) How it all works
Everything is Terraform, organized with Terragrunt into four layers:
network, data, app, and observability. Every pull request runs a plan
plus security scans. Merging to main deploys to testing on its own. If
a plan would delete or replace something, the pipeline stops and a
person has to handle it. The one exception is the self-signed TLS key
and cert, which only exist in Terraform state: renewing them (yearly,
30 days early) replaces them, and the ACM cert takes the new PEM in
place.

Only testing builds images. Stage and production get the same image,
by digest, through `promote.yml`: testing to stage, then stage to
production. A commit can only move up if it's on main and is what the
env below is running right now. The copy keeps the digest, so stage and
production run the exact bytes that were scanned. The commit SHA tag
goes along with it so people can see which commit is where. Stage is
started by hand. Production is started by hand or by pushing a `vX.Y.Z`
tag, never by a merge, and every production plan, apply and release
waits for a reviewer. Each env has its own CI roles, and each role only
trusts its own GitHub environment.

Proven on AWS on 2026-11-02, all at commit `6ddddb0`:
- Testing deploy, run 41500661903: succeeded.
- Stage promote, run 41510489704: succeeded.
- Production promote, run 41518904821: succeeded, with every production
  job waiting for a reviewer.
- Smoke tests passed in stage and production: `/health` reported
  `6ddddb0`, and `/ssn/tokenize` with `X-Caller: claimant-signup`
  returned a token and an HMAC.

4) What you need to run it
Required tools. The scripts check the versions in `scripts/lib.sh` and
stop if one is too old.
- AWS CLI v2, 2.32.0 or later. That's the first version with
  `aws login`, which signs the CLI in with your console sign-in.
  Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  (`aws login`: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- Terraform 1.17.0 or later. Runs the bootstrap and state bucket roots,
  and Terragrunt calls it for the layers.
  Install: https://developer.hashicorp.com/terraform/install
- Terragrunt 1.2.1 or later. Runs the four layers.
  Install: https://terragrunt.gruntwork.io/docs/getting-started/install/
- GitHub CLI `gh`, 2.55.0 or later. The bootstrap script uses it to set
  and read back the role ARN variables on the GitHub environments. Sign
  in with `gh auth login`. Its default scopes (`repo`, `read:org`,
  `gist`) are enough, since environment variables only need `repo`.
  Install: https://cli.github.com/
  (scopes: https://cli.github.com/manual/gh_auth_login and
  https://docs.github.com/en/rest/actions/variables#create-an-environment-variable)
- jq 1.6 or later. Reads plan and output JSON in the scripts.
  Install: https://jqlang.org/download/
- openssl 1.1.1 or later. Makes the pepper (section 8).
  Install: https://openssl-library.org/source/ (most systems have it)
- git. Install: https://git-scm.com/downloads
- bash. Git Bash on Windows works. macOS and Linux have it.
- Terragrunt and Terraform are only needed for `scripts/teardown.sh`
  and the bootstrap, not for the pipeline.

Git Bash on Windows:
- Git Bash doesn't always see what winget or an installer put on the
  Windows PATH, even after a restart. The scripts tell you which tool
  they can't find.
- jq: put `jq.exe` in `~/bin`, which Git Bash adds to the PATH:
  `mkdir -p ~/bin && curl -L -o ~/bin/jq.exe https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe`
- gh: the installer puts it in `/c/Program Files/GitHub CLI`. Add it:
  `echo 'export PATH="$PATH:/c/Program Files/GitHub CLI"' >> ~/.bashrc`
- If `~/bin` isn't on the PATH either, add it the same way:
  `echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc`
- Then open a new Git Bash window, or run `source ~/.bashrc`.
- Line endings: `.gitattributes` keeps every text file LF, even with
  `core.autocrlf=true`. A clone made before it was added still has CRLF
  files on disk. Once, after pulling it, from the repo root:
  `git stash` (only if `git status` shows changes you want to keep), then
  `git rm --cached -r -q . && git reset --hard`, then `git stash pop`
  if you stashed. That rewrites every tracked file from the repo with LF.
  `git reset --hard` throws away uncommitted changes to tracked files,
  which is why the stash comes first. Untracked and ignored files, like
  your tfvars, aren't touched. `git status` should be clean after.
- A GitHub account with admin on the repo, to create the environments,
  rulesets and variables.
- An AWS account you can sign in to with admin rights, for the bootstrap.

Set up from zero, from the repo root:
1. Fill in the tfvars. Copy each `terraform/bootstrap/*.tfvars.example`
   to the same name without `.example` (`testing.tfvars`, `stage.tfvars`,
   `production.tfvars`) and replace every `REPLACE-ME`. The script stops
   if one is left. Each env gets only its own file, with `-var-file`.
   Stage and production have to set everything testing's file sets, or
   the script stops and lists what's missing.
   Testing's file used to be `terraform.tfvars`. Terraform loads that
   name on its own, so it leaked into stage and production. If the old
   name is still there the script offers to rename it to
   `testing.tfvars`, once, after you type `yes`.
2. `scripts/bootstrap.sh state-bucket`, once. If
   `terraform/state-bucket/terraform.tfvars` is missing it writes one
   from the testing tfvars and the account you're signed in to, shows
   it, and asks once. The bucket name defaults to `state_bucket_name`,
   or `<owner>-migdemo-tfstate-<year>` if that isn't set. The first run
   imports the bucket if it already exists, or creates it, then moves
   its own state into the bucket. The scripts never destroy the state
   bucket.
3. Make the GitHub environments: `<env>-infra-plan`, `<env>-infra`,
   `<env>-app` for each env you'll run. The script sets variables on
   them but doesn't create them.
4. `scripts/bootstrap.sh all`, or one env at a time with
   `scripts/bootstrap.sh testing` (then `stage`, `production`). Testing
   goes first because it makes the GitHub OIDC provider the others use.
   One run does:
   - preflight: tool versions, AWS session (runs `aws login` if there's
     none), the account, tfvars with no `REPLACE-ME`, `gh` signed in
   - init and plan for each env, with a summary of what changes
   - one typed confirmation for all the plans
   - apply the saved plans, nothing re-planned
   - set `AWS_PLAN_ROLE_ARN`, `AWS_TERRAFORM_ROLE_ARN` and
     `AWS_DEPLOY_ROLE_ARN` on the env's three GitHub environments, then
     read each one back
   `--dry-run` stops after the plan and shows which GitHub variables
   would change. `--no-github` skips the GitHub step and prints the
   `gh variable set` commands instead. Every run logs to `logs/`.
   The account comes from `aws sts get-caller-identity`. To pin it, set
   `MIGDEMO_ACCOUNT_ID` or `expected_account_id` in
   `terraform/state-bucket/terraform.tfvars` (the generated file sets
   it). A pinned run stops on any other account.
5. Deploy. Merging to main deploys testing. Then run `promote.yml` to
   stage, then to production (section 3).
6. Tear down with `scripts/teardown.sh` (section 5).

Manual equivalent, for reference: `terraform init -reconfigure` in
`terraform/bootstrap` with the bucket, region and that env's state key
(see `backend.tf`), `plan -var-file=<env>.tfvars` (testing too), apply,
then copy the three role ARN outputs into the env's GitHub environments
by hand.

Provider lock files: every `.terraform.lock.hcl` has hashes for
linux_amd64, windows_amd64, darwin_arm64 and darwin_amd64, so `init` on
Windows, a Mac or CI doesn't rewrite it. After a provider version
changes, run `scripts/lock-providers.sh` from the repo root and commit
the lock files. It runs `terraform providers lock` with those four
platforms for bootstrap, state-bucket and every unit, keeps the locked
versions, and only talks to the Terraform registry, no AWS. Check
`git diff` after: only hashes should change.

State encryption: the state bucket's default is SSE-KMS with
`alias/migdemo-tfstate`, but Terraform's S3 backend sends its own
encryption header, AES256, unless `kms_key_id` is set. `root.hcl` and
`scripts/bootstrap.sh` set it, so state and lock files use the key.
- Which key: `TF_STATE_KMS_KEY` when it's set, and set but empty
  (`export TF_STATE_KMS_KEY=`) means no key. Otherwise both follow
  `use_kms` in `terraform/state-bucket/terraform.tfvars`: with
  `use_kms = false` there's no key, so `kms_key_id` is left off and state
  is SSE-S3. No tfvars file, or no `use_kms` in it, means the key.
- CI has no state-bucket tfvars, so it always uses the key. If the bucket
  was made with `use_kms = false`, add `TF_STATE_KMS_KEY: ""` to the
  env of the workflows that run terragrunt (`pr.yml`, `infra.yml`,
  `tg-plan.yml`, `tg-apply.yml`).
  `bash scripts/tests/state-kms-key.sh` checks root.hcl and bootstrap.sh
  agree.
- Access: the key policy lets the CI roles use the key only through S3,
  only for this bucket, and only Decrypt and GenerateDataKey, which is
  all SSE-KMS needs. Every CI role is denied the key outside S3
  (`NoStateKeyOutsideS3`). The plan role gets no KMS allow of its own,
  and the S3 denies still keep each role to its own env's state.
- After pulling this, run `terragrunt init -reconfigure` in any unit you
  already inited locally, since the backend config changed.
- Rollout, from the repo root:
  1. `scripts/bootstrap.sh state-bucket --dry-run`, then without
     `--dry-run`. Re-inits that root with the key.
  2. `scripts/bootstrap.sh all` (or one env at a time). Adds the deny to
     the CI roles and re-inits each bootstrap backend with the key.
  3. Run deploy (`deploy.yml`, Run workflow) or merge the next change.
- Older state stays SSE-S3 until it's written again.
  `scripts/reencrypt-state.sh --dry-run` lists what isn't on the key.
  Without `--dry-run` it copies each one in place after you type
  `reencrypt`. Run it when nothing else is running terraform. Old
  versions stay SSE-S3 until the lifecycle rule expires them.
- Once every env has been re-inited, `deny_non_kms_uploads = true` in
  `terraform/state-bucket/terraform.tfvars` makes the bucket refuse
  uploads that ask for SSE-S3. Uploads with no header still get the
  bucket default key. `bash scripts/tests/reencrypt-state.sh` checks the
  script with a fake aws.
- After that, `deny_wrong_kms_key = true` makes the bucket refuse
  uploads that name any other KMS key. It allows this key by ARN, key id,
  alias name and alias ARN, since S3 doesn't document whether it resolves
  an alias first. No key id header still gets the bucket default key.
  CI can't create, move or delete the alias (`DenyCiKeyAdmin`).
  Apply with `scripts/bootstrap.sh state-bucket --dry-run`, then without
  `--dry-run`. To back it out, set it to false and run it again.

Also needed:
- Repo variables: `TF_STATE_BUCKET`, `AWS_REGION`, `OWNER`,
  `BUDGET_EMAIL`, `ALB_INGRESS_CIDRS` (your IP as a /32)
- Confirm the SNS alarm email after the first deploy
- Budget about $3 a day while it's running

Access review:
- Each env has three CI roles. Plan is read only, plus its own state
  lock and saved plans. Terraform (apply) is PowerUser plus IAM for its
  own env's roles, each with a permissions boundary. Deploy pushes its
  own images, registers task definitions, runs the migration task and
  rolls its own ECS services.
- All three are denied the database logins, the SSN key and pepper,
  other envs' state, saved plans, secrets and keys, and assuming any
  other role. The vault roles' trust can't be changed from CI.
- Terraform (apply) can't run tasks, and can't create, change or delete
  ECS services outside its own env's cluster.
- The state bucket and its key deny CI admin by role name,
  `role/migdemo-*-github-*`. The github_oidc tests fail if a CI role
  name stops matching.
- Check every few months, or after the account sits idle, that the
  roles still only trust their own GitHub environments and nothing else
  in the account trusts an outside account.
- Changes to these roles only take effect after you run
  `scripts/bootstrap.sh <env>` by hand. CI never applies bootstrap.

For stage and production, on top of that:
- Their bootstrap tfvars must set `create_github_oidc_provider = false`.
  They reuse the provider testing's bootstrap made.
- The env variables on `<env>-infra-plan`, `<env>-infra` and `<env>-app`
  override the repo-level testing values, and the pipeline refuses a
  role that isn't for its env.
- Stage environments: main branch only. Production environments: main
  and `v*` tags, with a required reviewer on all three.
- A tag ruleset so only you can create `v*` tags.
- Setup gotcha: a tfvars copied from its `.example` still has
  `REPLACE-ME` values. The script stops on them now. Applied by hand,
  the env's plan role gets a state lock policy for the wrong bucket and
  the first promote fails at network-plan with AccessDenied on
  `s3:PutObject` for the `.tflock` file. Fix: set the real values and
  run the bootstrap again. It only updates policies in place.
- After the first deploy of each env: set its pepper once (section 8)
  and confirm its alarm email. Tokenize answers 503 until the pepper is
  set.
- Smoke test: `/health`, then `/ssn/tokenize` with a fake 9xx SSN.
  Stage and production need `X-Caller: claimant-signup`. `demo` only
  works in testing. Use the `app_url` output (https). With the
  self-signed cert, add `-k`:
  `curl -k "$ALB/health"`. To check the cert instead of skipping the
  check, save the `self_signed_cert_pem` output to a file and use
  `curl --cacert alb.pem "$ALB/health"`. `http://` still works and
  answers 301 to the https URL.
- A real cert: put a public Route 53 hosted zone for your domain in the
  account, then set `domain_name` (for example `app.example.com`) and
  `route53_zone_id` in that env's env.hcl. The plan requests an ACM
  cert, validates it with DNS records in the zone, adds an alias record
  to the ALB and points the listener at it. ACM renews it on its own.
  Drop `-k` after that. The same plan deletes the self-signed cert from
  ACM, and the pipeline's delete check stops any plan with a delete, so
  that one switch is an apply you run by hand.
- The WAF answers 403 to requests from outside `waf_geo_allow_countries`
  (US by default) and to Tor exits, open proxies and VPN ranges. A smoke
  test from a VPN or from abroad gets a 403 from the WAF, not the app.
  Cloud provider IP ranges (`HostingProviderIPList`) are only counted,
  not blocked.
- Stage costs about $8 to $9 a day while it's up (multi-AZ endpoints, an
  Aurora floor that doesn't pause, ALB, WAF, four tasks). Bring it up to
  prove a release, then tear it down. Every budget is account-wide, so
  testing's budget alerts while stage runs.

5) How it tears down
Teardown is manual on purpose so the pipeline can never delete things
on its own. From the repo root:

```bash
./scripts/teardown.sh testing --dry-run
./scripts/teardown.sh testing
```

Use `stage`, `production` or `all` the same way. `all` goes
production, then stage, then testing, and skips any env with nothing
up. One run does:
- preflight: tool versions, an AWS session (a real run always signs in
  fresh), and the account, region and tagged resource count for each env
- a destroy plan for each unit, observability, app, data, network, with
  a summary
- one typed confirmation, the env name or `all`
- apply the saved plans in that order, nothing re-planned. It checks the
  AWS session before each unit and signs in again if it ran out. It
  stops at the first failure. Run it again after a fix and the units
  that are already gone plan as no changes and get skipped.
- check that nothing is left: RDS, ALB, ECS, VPC endpoints, VPC, WAF.
  It exits non-zero if anything is.

`--dry-run` stops after the plans. Every run logs to `logs/`.
The summary counts come from `terraform show -json` on each saved plan,
with the plan text as a backup. `bash scripts/tests/teardown-plan-summary.sh`
checks that part with fake terragrunt output, no AWS needed.
`bash scripts/tests/bootstrap-tfvars.sh` checks the bootstrap tfvars
handling the same way. The PR workflow runs both, plus shellcheck.

The units need the same values the pipeline passes in. It reads
`TF_STATE_BUCKET` and `MIGDEMO_OWNER` from
`terraform/bootstrap/testing.tfvars`,
and `MIGDEMO_BUDGET_EMAIL` and `MIGDEMO_ALB_INGRESS_CIDRS` from the
`BUDGET_EMAIL` and `ALB_INGRESS_CIDRS` repo variables with `gh`. Set
any of them in the environment to override.

Tearing down testing while stage or production is up, or stage while
production is up, warns first. Stage and production promote by digest
from the env before them, and tearing down testing deletes its images,
so nothing can be promoted until testing is deployed again. It deletes
the backups too.

Teardown never touches the bootstrap (CI roles) or the state bucket. To
retire an env for good, tear it down, then run
`scripts/bootstrap.sh destroy <env>`. It refuses while the env still
has tagged resources, and refuses testing while stage or production
still has a bootstrap. No script destroys the state bucket.

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
- Audit trail: four actions, one row each, always who, never the SSN, the
  HMAC, the token or a ticket value. `ssn.ticket_issue` and
  `ssn.ticket_refresh` (`record_type` `ssn_ticket`) and `ssn.reveal`
  (`record_type` `ssn_vault`, with the ticket id and claim id) also have
  a reason. `ssn.tokenize` (`record_type` `ssn_vault`, the vault row id)
  has the caller as the actor, no reason, and `{"created": true}` for a
  new SSN or `false` for one the vault already had. Each is written in
  the same transaction as the change or lookup it records. No audit row,
  no change and no answer.

Endpoints:
- `POST /ssn/tokenize` takes `{"ssn": "..."}` and returns the token and
  HMAC. 201 the first time, 200 after that. Because 201 versus 200 says
  whether an SSN is already known, it needs an allowed caller in
  `X-Caller` and writes an `ssn.tokenize` audit row for every 201 and
  200. A missing or unknown caller gets 403 `caller not allowed`, the
  same for both, with no audit row. 400 for a bad SSN.
- Allowed callers are `claimant-signup` and `wage-loader`
  (`ssn/callers.py`). `demo` is allowed too, but only in a `-testing`
  environment, decided the same way as `/demo/seed-claim` below.
  `SSN_TOKENIZE_CALLERS` (comma separated) replaces the list; bad names
  and `demo` in it are dropped, and if nothing valid is left the default
  is used. Not set today, for the same reason as the limits below.
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
- The actor comes from `X-Actor` for now, and the tokenize caller from
  `X-Caller`. Both are headers the client sets, so anyone who knows an
  allowed caller name can send it. The caller check keeps casual callers
  out and names the caller in the audit row, but it is not proof of who
  called. That is the same gap as the verified identity in the roadmap
  (section 9).
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
- The vault adds a limit per actor (`ssn/ratelimit.py`). The WAF can't
  tell two staff behind one office IP apart, and it can't stop one actor
  spread over many IPs. The vault only sees the app's IP, so it keys on
  `X-Actor` instead. Each actor gets 5 reveals and 10 ticket calls (issue
  and refresh together) in any 60 seconds, and each tokenize caller gets
  60 tokenize calls, then a 429 `{"detail": "too many requests"}` with
  `Retry-After` and `no-store`. Every request with an actor and a reason,
  or an allowed caller, counts, 404s and 400s included. A 403 or a 429
  doesn't count.
- The limit is kept in memory in each vault task. With 2 vault tasks an
  actor can get up to twice the limit, a little more during a deploy, and
  a task restart clears the count. `X-Actor` is a header for now, so a
  caller who changes it every request gets past this limit; the WAF limit
  by IP still applies. Both get fixed by the verified identity below.
- `SSN_REVEAL_LIMIT_PER_MINUTE`, `SSN_TICKET_LIMIT_PER_MINUTE` and
  `SSN_TOKENIZE_LIMIT_PER_MINUTE` change the limits (1 to 1000). A bad value falls back to the default, so a
  typo can't turn the limit off. Neither is set today. Setting one is a
  task definition change, which the pipeline blocks as a replace (see
  "Why it's built this way"), so change the default in code instead.
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

SSN audit alarms (same file, same topic). The vault writes a metric line
as it commits each audit row, refuses a ticket or answers 429
(`app/src/demo_app/ssn_events.py`). The lines carry the route and a
category, never the actor, a ticket, a token or an SSN. All are in
`MigDemo/SsnVault`, dimension `NamePrefix`, summed over 5 minutes across
all vault tasks:
- `<name_prefix>-ssn-reveals-high`: at least 30 `ssn_reveal` (threshold
  `ssn_reveals_count`).
- `<name_prefix>-ssn-ticket-rejections-high`: at least 10
  `ssn_ticket_rejected` (threshold `ssn_ticket_rejections_count`). That
  is every 404 on reveal and refresh, and every ticket asked for a claim
  that isn't open.
- `<name_prefix>-ssn-closed-claim-attempt`: at least one
  `ssn_closed_claim_attempt`, a reveal or refresh with a ticket whose
  claim has closed.
- `<name_prefix>-ssn-rate-limited`: at least one `ssn_rate_limited`, a
  429 from the vault's per-actor or per-caller limit. The WAF's own 429s
  show up in the WAF metrics instead.
- `<name_prefix>-ssn-tokenize-caller-rejected`: at least one
  `ssn_caller_rejected`, a 403 on `/ssn/tokenize` for a missing or
  unknown `X-Caller`. A service sending the wrong name, or someone
  probing for known SSNs.

First checks when one fires:
1. `audit_event` has the who and why. For example, reveals in the last
   hour by actor:
   `SELECT actor, count(*) FROM audit_event WHERE action = 'ssn.reveal' AND occurred_at > now() - interval '1 hour' GROUP BY actor ORDER BY 2 DESC;`
2. The vault log, `/ecs/<name_prefix>/ssn-vault`. `ssn_ticket_rejected`
   lines have a `reason` (`unknown`, `malformed`, `expired`, `used`,
   `revoked`, `claim_closed`, `not_holder` or `no_open_claim`).
   `ssn_rate_limited` lines have the `bucket` and the `limit`.
   `ssn_caller_rejected` lines have a `reason` (`no_caller` or
   `unknown_caller`), never the name that was sent.
3. Refusals and 429s have no audit row, and no log names the actor. The
   WAF logs redact `x-actor` and `x-reauth-actor`, so they give the client
   IP, the time and the path only. Match them to the vault log lines by
   time and route to find the IP. For anything that succeeded,
   `audit_event` has the actor.

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
- Key policy (`terraform/modules/ssn_vault`): only the vault task role can
  use the key on SSN data. It may Encrypt and Decrypt with `purpose=ssn`,
  Decrypt the pepper through Secrets Manager, and DescribeKey. The account
  keeps key administration (describe, policy, rotation, tags, aliases,
  deletion) but no Encrypt, Decrypt or CreateGrant, so IAM alone can't
  give anyone else the key. Two narrow account statements are left, both
  through Secrets Manager only: GenerateDataKey on the pepper secret, so an
  operator can set the pepper (but not read it back), and the throwaway
  check Secrets Manager runs when a secret is created with this key.
- IAM, on the CI roles (plan, apply and deploy, `terraform/modules/github_oidc`,
  applied with bootstrap): explicit Deny on the SSN key, matched by its
  alias, except that creation check, and on GetSecretValue and
  PutSecretValue under `<name_prefix>/ssn/`. Terraform never reads the
  pepper. It creates the secret, not its value.
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
1. Apply `terraform/bootstrap` so the vault boundary has the SSN statements
   and the CI roles have the SSN denies. CI never applies bootstrap.
2. Merge and let the deploy run. It adds the KMS endpoint, the IAM
   statements and the login.
3. Set the pepper once, out of band, as 64 hex characters (32 random
   bytes). Never change it afterwards: a new pepper breaks every
   `ssn_hmac` match. Run it with your own admin role, not a CI role. The
   key policy lets you set it but not read it back.
   `aws secretsmanager put-secret-value --secret-id <name_prefix>/ssn/hmac-pepper --secret-string "$(openssl rand -hex 32)"`
4. The next `/ssn` request picks it up within 30 seconds. Check it with a
   fake SSN in the 9xx range (never a real one):
   `curl -k -X POST "$ALB/ssn/tokenize" -H "Content-Type: application/json" -H "X-Caller: demo" -d '{"ssn":"900-12-3456"}'`
   `demo` only works in testing. In stage or production send
   `X-Caller: claimant-signup` instead. Do this once per env. `$ALB`
   is the https `app_url`; `-k` is for the self-signed cert.

If it answers 503, the vault log (`/ecs/<name_prefix>/ssn-vault`) names
the step that failed and nothing else, for example
`KMS key lookup failed (AccessDeniedException)`. AWS calls give up after
a 3 second connect or 5 second read, with one retry, so a missing route shows up as a quick 503 instead of a load balancer
504. Bringing it up in testing hit both: a 504 from the missing KMS
endpoint, then AccessDenied from the boundary. The two fixes are above.

Aurora auto-pauses when idle, and the first connection wakes it. The
vault's database connect timeout is 23 seconds (`DB_CONNECT_TIMEOUT`, a
code default in `ssn_api.py` and `db.py`). It was 20, and in testing the
first call after a pause ran out at 20 seconds with `database call failed:
ConnectionTimeout` and a 503 after 22.6 seconds in all. The next call
worked. The app waits 30 seconds for the vault (`READ_TIMEOUT` in
`ssn_vault_client.py`), which covers the 23 second connect plus a fresh
vault task's startup lookups. The ALB idle timeout is the default 60
seconds. If a wake ever takes longer than 23 seconds, the first call still
gets a 503 and the next one works. Change the default in code, not in the
task definition.

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
# The self-signed cert needs -k. Drop it once domain_name is set.
ALB=https://<your-alb-dns-name>
curl() { command curl -k "$@"; }
J="Content-Type: application/json"
TOK=$(curl -s -X POST "$ALB/ssn/tokenize" -H "$J" -H "X-Caller: demo" -d '{"ssn":"900-12-3456"}'); echo "$TOK"
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
- Tokenize answers 201 or 200, so it can tell whether an SSN is known.
  Only allowed callers get an answer, each answer has an audit row
  naming the caller, each caller is limited to 60 a minute, and every
  refusal is a metric with an alarm. The caller is a header anyone can
  set, though, so a caller who knows an allowed name still gets through,
  limited and recorded under that name.
- Every reveal is attributable and has a reason. The vault and app logs
  never carry the SSN, the token, a ticket or the actor, and mask anything
  shaped like an SSN. The WAF logs record request headers, with
  `x-actor`, `x-reauth-actor`, `authorization` and `cookie` redacted.
  WAF log lines written before that redaction still have the actor until
  they age out.
- CI can manage the SSN key but can't use it or read the pepper.
- A leaked `tok_` value reveals nothing. A leaked ticket works once, for
  at most 72 hours, and only while its claim is open.

Code: `app/src/demo_app/ssn/` (`config.py` is the startup lookup). Key,
pepper secret and IAM: `terraform/modules/ssn_vault`.

Known trade-offs:
- The account keeps administration of the SSN key as a break glass. An
  account admin with `kms:PutKeyPolicy` can widen the key policy, so admin
  roles in this account are part of the trust boundary. The CI apply role
  can too, because Terraform manages the policy. Such a change shows in
  the plan and the pull request, and CloudTrail records every
  PutKeyPolicy.
- The CI denies match the key by its alias, because bootstrap can't know
  the key ARN. Removing the alias lifts those denies. The key policy still
  gives CI no Encrypt or Decrypt, so both would have to change.

9) Roadmap
Future installments. None of these are built yet.

SSN service:
- Verified identity (ALB OIDC or Cognito) for the actor, with a "may
  reveal" role check, replacing the `X-Actor` header.
- Real re-auth for refresh (identity provider step-up), replacing the
  `X-Reauth-Actor` and `X-Reauth-At` placeholder.
- Mutual TLS between services. Prove the calling service (mutual TLS, a
  signed service token or SigV4) instead of trusting `X-Caller`, and
  encrypt app to vault traffic, which is plain HTTP on 8080 today.
- Hashed tickets: store a hash of the ticket instead of the value, and
  maybe require the same actor at reveal as at issue.
- A shared rate limit store (DynamoDB or ElastiCache), so the per-actor
  limit is exact across vault tasks and survives a restart.
- A ticket cleanup job that deletes tickets that are long dead.
- A key rotation re-encrypt job (rows record their key ARN).
- Two-person approval for bulk reveal.
- Tell `claim_closed` apart from `no_open_claim` on ticket issue. That
  needs a store change.
- Claimant sign-up and the wage loader calling tokenize, sending
  `X-Caller`.

Platform:
- Pin first-party GitHub actions (`actions/checkout`, `actions/setup-python`
  and the rest) to commit SHAs. Most use version tags today.
- Extend `stale-stack.yml` to stage. It only checks testing today.
- Scan images again at promotion. Today promotion copies the digest
  Trivy scanned in testing and doesn't scan again.
- A separate AWS account per env. All three share one account today.
