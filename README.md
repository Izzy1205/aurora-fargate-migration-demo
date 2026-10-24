# aurora-fargate-migration-demo

A small AWS stack I use to show a zero-downtime schema change. Aurora
PostgreSQL Serverless v2, a Python API on Fargate behind an ALB, all of it in
Terraform. Flyway runs the migrations as a one-off ECS task from the pipeline.

The demo is one pull request (`add-order-priority`) that adds a `priority`
column to `orders` as an expand-only migration. The running app keeps working
the whole time, and the new code treats NULL as "not set yet".

```mermaid
flowchart LR
    user([Browser from your IP only]) -->|HTTP 80| alb[ALB<br/>public subnets]

    subgraph vpc[VPC 10.40.0.0/16, no NAT gateway]
        alb -->|8000| app[ECS Fargate<br/>app service<br/>private subnets]
        mig[ECS Fargate<br/>Flyway task<br/>run once per release] -->|5432| db[(Aurora PostgreSQL<br/>Serverless v2<br/>private subnets)]
        app -->|5432| db
        app -.-> vpce[VPC endpoints<br/>ECR, Secrets Manager, Logs, S3]
        mig -.-> vpce
    end

    vpce -.-> sm[Secrets Manager<br/>RDS managed secret]
    vpce -.-> ecr[ECR<br/>app and migrate images]
    vpce -.-> cw[CloudWatch Logs]

    subgraph gha[GitHub Actions]
        pr[pr.yml<br/>plan role, read only]
        infra[deploy.yml infra job<br/>terraform role]
        rel[deploy.yml release job<br/>deploy role]
    end

    infra -->|terraform apply| vpc
    rel -->|push images, run task,<br/>update service| ecr
    rel -->|ecs:RunTask| mig
```

The private subnets have no route to the internet. Tasks reach ECR, Secrets
Manager and CloudWatch Logs through interface endpoints and pull image layers
through the S3 gateway endpoint. No NAT gateway.

## Who owns what

Terraform owns the infrastructure and Flyway owns the schema. They run in
separate jobs with separate IAM roles, and neither can do the other's job.

| Thing | Owner | How it changes |
|---|---|---|
| VPC, subnets, security groups, endpoints | Terraform | `deploy.yml` infra job |
| Aurora, ALB, ECS cluster, ECR, log groups, budget | Terraform | `deploy.yml` infra job |
| Task definition shape (CPU, memory, env, secrets) | Terraform | `deploy.yml` infra job |
| Which image a task runs | Pipeline | release job registers a new revision |
| Tables, columns, constraints, seed data | Flyway | `db/migrations/`, run by the release job |
| DB master password | RDS | RDS creates and rotates it in Secrets Manager |
| OIDC provider and the three CI roles | `terraform/bootstrap` | applied by hand, once |

The CI roles:

| Role | Used by | Can | Can't |
|---|---|---|---|
| `migdemo-demo-github-plan` | `pr.yml` | read the account and state | write anything, read the DB secret |
| `migdemo-demo-github-terraform` | infra job, `production-infra` env | create and change the stack | read the DB secret, run tasks, touch the CI roles |
| `migdemo-demo-github-deploy` | release job, `production-app` env | push to ECR, register task defs, run the migrate task, update the service | change infra, read the DB secret |

The ECS execution roles can pull their own image, write their own logs and
read the DB secret to inject it. The task roles have no policies at all,
since neither container calls AWS.

I kept the CI roles in their own Terraform root so the pipeline can't edit its
own permissions. The DB password only exists inside the running containers.
ECS injects it from Secrets Manager at start-up, so it's not in state, not in
GitHub and not in this repo.

## Expand and contract

Schema changes go out in steps so the code that's running never sees a schema
it doesn't understand:

1. Expand: add only. New columns are nullable with no default, new
   constraints go in as `NOT VALID`, nothing gets renamed or dropped. Old code
   ignores the column, new code handles NULL.
2. Ship code that reads and writes the new column.
3. Backfill old rows in small batches, as its own release.
4. Contract: once nothing depends on the old shape, validate constraints, set
   defaults and NOT NULL, drop what's unused.

A few other rules. Migrations run before the new app version rolls out, which
is only safe because they're expand-only. Each one sets `lock_timeout` so a
blocked `ALTER TABLE` fails fast instead of stacking every query up behind
it. Merged migrations are never edited (Flyway's checksums catch it), `flyway
clean` is disabled, and the app selects columns by name, never `SELECT *`.

`db/future/` has V4 (backfill) and V5 (enforce) to show what the next two
releases look like. Flyway doesn't read that folder.

## Layout

```
.github/workflows/      pr.yml (checks + read-only plan), deploy.yml, codeql.yml
.github/dependabot.yml  weekly version bumps
terraform/              main stack (network, database, registry, ecs, budget)
terraform/bootstrap/    OIDC provider and CI roles, applied by hand
db/migrations/          Flyway migrations
db/future/              contract steps, not applied
db/Dockerfile           Flyway image with the migrations baked in
app/                    FastAPI app, tests, Dockerfile
scripts/                helpers the release job calls
```

## Setup

You need Terraform 1.9+, AWS CLI v2 and admin credentials for the one-time
bootstrap. None of these values are secrets, but the tfvars and backend files
are gitignored anyway.

| Value | Goes in |
|---|---|
| Region | `terraform.tfvars`, `bootstrap/terraform.tfvars`, `backend.hcl`, var `AWS_REGION` |
| State bucket | `backend.hcl`, `bootstrap/terraform.tfvars`, var `TF_STATE_BUCKET` |
| GitHub repo (`owner/name`) | `bootstrap/terraform.tfvars` |
| Budget email | `terraform.tfvars`, var `BUDGET_EMAIL` |
| Your IP as a /32 | `terraform.tfvars`, var `ALB_INGRESS_CIDRS` (JSON, e.g. `["203.0.113.10/32"]`) |
| Owner tag | `terraform.tfvars`, var `OWNER` |

Check that the Aurora version (`aurora_engine_version` in
`terraform/variables.tf`, default `16.9`) is offered in your region. Scale to
zero needs 16.3 or newer on the 16 line.

```
aws rds describe-db-engine-versions --engine aurora-postgresql \
  --query 'DBEngineVersions[].EngineVersion' --output text
```

### 1. State bucket

Once, by hand. New buckets get SSE-S3 by default.

```
aws s3api create-bucket --bucket <state-bucket> --region <region>
# outside us-east-1, also pass:
#   --create-bucket-configuration LocationConstraint=<region>
aws s3api put-bucket-versioning --bucket <state-bucket> \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket <state-bucket> \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 2. Bootstrap the CI roles

Run this locally with admin credentials. It's the only Terraform that doesn't
go through the pipeline.

```
cd terraform
cp backend.hcl.example backend.hcl                                # fill in
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars  # fill in
cd bootstrap
terraform init -backend-config=../backend.hcl \
  -backend-config="key=aurora-fargate-migration-demo/bootstrap.tfstate"
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

If the account already has a GitHub OIDC provider, set
`create_github_oidc_provider = false`. If the plan job fails with "Not
authorized to perform sts:AssumeRoleWithWebIdentity", GitHub is sending the
immutable subject format; see the comment in `terraform.tfvars.example`.

### 3. GitHub

- Repo variables (Settings > Secrets and variables > Actions > Variables): the
  ones in the table above, plus the three role ARNs from step 2 as
  `AWS_PLAN_ROLE_ARN`, `AWS_TERRAFORM_ROLE_ARN` and `AWS_DEPLOY_ROLE_ARN`.
  No AWS keys go in GitHub.
- Environments `production-infra` and `production-app`, each with a required
  reviewer and deployments limited to `main`. The role trust policies only
  accept tokens from these environments.
- Branch protection on `main`: require a PR and the `pr` checks.

### 4. First deploy

`deploy.yml` is manual for now. Run it from the Actions tab on `main`. The
infra job takes 10 to 15 minutes (mostly Aurora), then the release job pushes
the images, runs the migrations and starts one app task. The run summary
prints the app URL. Confirm the budget subscription email AWS sends you.

Terraform creates the ECS service with 0 tasks and a placeholder image tag,
since the images don't exist yet on the first run. The release job sets the
real image and scales it to 1. To deploy on every merge instead, add a `push`
trigger for `main` at the top of `deploy.yml`.

## Running the demo

1. Open the app URL. Orders show, no priority yet.
2. Open a PR from `add-order-priority`. In the checks, the plan shows no infra
   change, and the Flyway job runs V1 and V2 against a throwaway Postgres,
   then V3, then confirms every existing row still has `priority` NULL. Walk
   through the migration itself: nullable column, `NOT VALID` check,
   `lock_timeout`.
3. Merge, run deploy, approve `production-infra` (no-op apply) and then
   `production-app`.
4. Flyway runs V3 in the private subnets, then the app rolls. The old task
   keeps serving the whole time.
5. Refresh. Every row shows `standard (default, NULL in DB)`. Nothing was
   rewritten.
6. Talk through `db/future/`: backfill next release, enforce the one after.

```
curl http://<app_url>/health        # liveness, no DB
curl http://<app_url>/ready         # opens a DB connection
curl "http://<app_url>/orders?limit=5"
```

If Aurora has paused, the first request takes about 15 seconds. Hit `/ready`
before you start to wake it up.

## Running locally

```
cd app
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
pytest
```

The tests use a fake repository, no database needed. To try the migrations
against a local Postgres:

```
docker run --rm -d --name pg -e POSTGRES_PASSWORD=local -p 5432:5432 postgres:16
docker build -t demo-migrate db
docker run --rm --network host \
  -e FLYWAY_URL=jdbc:postgresql://localhost:5432/postgres \
  -e FLYWAY_USER=postgres -e FLYWAY_PASSWORD=local demo-migrate migrate
```

## Cost

Not free tier (Aurora never is). New account credits cover it easily, but
check your balance. Rough us-east-1 numbers while it's up:

| Item | Approx. |
|---|---|
| Aurora Serverless v2 | ~$0.12 per ACU-hour when active, $0 compute when paused (after 5 idle minutes), plus storage |
| ALB | ~$0.023/hour plus traffic and public IPv4 |
| Fargate, one 0.25 vCPU / 0.5 GB task | ~$0.01/hour |
| 4 interface endpoints, one AZ | ~$0.04/hour (double with `single_az_endpoints = false`) |
| RDS managed secret | $0.40/month, prorated |
| ECR, CloudWatch Logs | cents |

Call it $0.10 to $0.40 an hour depending on how busy the DB is, or a few
dollars for a day left idle. Skipping the NAT gateway is what keeps it this
low.

The $10 monthly budget emails at 80% of actual and 100% of forecast, account
wide. It only alerts, it doesn't stop anything. Tearing down is the real cost
control.

## Teardown

There's no destroy workflow, on purpose. From your machine with admin
credentials:

```
cd terraform
terraform init -backend-config=backend.hcl
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

ECR repos use `force_delete` and the cluster skips its final snapshot so
destroy doesn't hang on either. Both are demo-only settings. If you're done for
good, destroy `terraform/bootstrap` the same way and delete the state bucket
(empty all object versions first).

Things to check in the region afterwards:

- [ ] RDS: no clusters, no instances, no manual snapshots
- [ ] Secrets Manager: no `rds!cluster-...` secret (deleted with the cluster)
- [ ] ECS: no clusters or running tasks
- [ ] EC2 > Load Balancers and Target Groups: empty
- [ ] VPC: the `migdemo-demo` VPC and its endpoints are gone
- [ ] EC2 > Network Interfaces: nothing left from endpoints or tasks
- [ ] EC2 > Elastic IPs: none (this stack creates none, check anyway)
- [ ] ECR: no `migdemo-demo/*` repos
- [ ] CloudWatch Logs: no `/ecs/migdemo-demo/*`, `/aws/rds/cluster/migdemo-demo-*`, or flow log groups
- [ ] IAM: `migdemo-demo-*` roles gone (after bootstrap destroy as well)
- [ ] Budgets: the demo budget is gone, or keep it on purpose
- [ ] S3: state bucket deleted, or kept on purpose
- [ ] Billing > Bills the next day: nothing still accruing

## Security checks

Every PR to `main` runs:

- `terraform fmt`, `validate` and `tflint`, then a plan from the read-only role
  posted as a PR comment
- Checkov on the Terraform. Skipped checks are listed with reasons in
  `.checkov.yaml`
- Gitleaks over the full git history, not just the diff
- Bandit (fails on medium or higher) and CodeQL on the app, plus CodeQL on the
  workflow files. CodeQL also runs on `main` and weekly
- pip-audit on the pinned Python packages
- Trivy on both images, built on the runner and never pushed. Fails on any
  fixable HIGH or CRITICAL, results go to the Security tab
- The Flyway migration test and pytest

Only the plan job uses AWS credentials, and it's skipped on fork PRs since
they don't get an OIDC token.

The deploy workflow scans both images again before pushing to ECR. A fixable
CRITICAL stops the release, and what gets pushed is the exact image that was
scanned. Dependabot watches the Python pins, both Dockerfiles, the Actions
and the Terraform providers.

Trivy's action is pinned to a commit SHA rather than a tag because its tags
were hijacked in March 2026 to steal CI secrets (GHSA-69fq-xp46-6x23).

To run the same checks locally:

```
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate
(cd terraform && tflint --init && tflint --recursive --config "$PWD/.tflint.hcl")
checkov --config-file .checkov.yaml
actionlint
gitleaks git .
(cd app && pytest)
bandit -r app --exclude app/tests,app/.venv --severity-level medium --confidence-level medium
pip-audit -r app/requirements.txt -r app/requirements-dev.txt
```

`.pre-commit-config.yaml` runs gitleaks and `terraform fmt` on commit if you use
pre-commit.

## What I'd add for production

This is sized for a demo with fake data. The gaps are deliberate:

- A NAT gateway or egress proxy per AZ if the app ever calls outside APIs, and
  endpoints in every AZ.
- An Aurora reader in a second AZ, two or more app tasks, and min ACU above 0
  so nobody waits on a resume.
- HTTPS: a domain, an ACM cert, a modern TLS policy, HTTP redirected. WAF in
  front with the managed rule groups and rate limiting.
- Separate DB roles: one that owns the schema for migrations and one for the
  app with only the grants it needs, ideally with IAM auth (already turned on).
- Customer managed KMS keys for Aurora, the secret, ECR and logs.
- Deletion protection, final snapshots, longer backup and log retention, an
  AWS Backup plan.
- Performance Insights, Container Insights, ALB access logs and CloudWatch
  alarms.
- Every action pinned to a SHA, a hand-written policy instead of
  `PowerUserAccess` on the terraform role, and a narrower plan role
  (`ReadOnlyAccess` can still read S3 objects).

The deploy role decides what code runs next to the DB secret, so code review
and the environment reviewers are the real control on releases. The skips in
`.checkov.yaml` line up with this list.
