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
- Stores data in Aurora PostgreSQL. The app and Flyway each log in as
  their own role with a password in Secrets Manager. The app can only
  read and write rows; Flyway owns the schema. The master password stays
  with RDS for break-glass and is never given to the app or Flyway.
  Each environment runs a writer and a reader in different AZs. If the
  writer fails, Aurora promotes the reader, usually in under 60 seconds.
  With no reader it has to rebuild the writer, usually in under 10
  minutes. One line in env.hcl (`aurora_instance_count`) sets how many.
- Holds a paid family and medical leave data model in the schema (V6 to
  V9): claimants, employers, wages, claims, leave, benefit weeks,
  payments, documents, and an audit trail. SSNs are only a token plus a
  keyed hash, and the database refuses a second payment for the same
  claim and week. Payments and audit rows are add-only for the app login.
  The tokenization service that fills in those tokens is next.
- Sends payment requests through an SQS queue with a dead letter queue
- Watches it all with 15 CloudWatch alarms and a dashboard

3) How it all works
Everything is Terraform, organized with Terragrunt into four layers:
network, data, app, and observability. Every pull request runs a plan
plus security scans. Merging to main deploys to testing, and someone
still has to approve infra changes. If a plan would delete or replace
something, the pipeline stops and a person has to handle it. Production
is always a manual deploy. 

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
check each plan, and type yes. The bootstrap stays until you remove
it yourself.

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