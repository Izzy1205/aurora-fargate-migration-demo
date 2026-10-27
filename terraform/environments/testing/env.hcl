# testing: the environment the demo actually runs in. Same region, sizes and
# task count the flat stack used.

locals {
  environment = "testing"
  aws_region  = "us-east-2"

  # Existing bucket, created by hand. The name stays out of the repo: set
  # TF_STATE_BUCKET locally, CI sets it from the TF_STATE_BUCKET variable.
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE-ME-tfstate-bucket")

  vpc_cidr = "10.40.0.0/16"
  multi_az = false # interface endpoints in one AZ to halve their cost

  aurora_engine_version           = "16.9"
  aurora_min_capacity             = 0
  aurora_max_capacity             = 2
  aurora_seconds_until_auto_pause = 300
  db_name                         = "demo"

  app_desired_count = 2 # one task per AZ
  budget_limit_usd  = 10

  # Alarm thresholds. Empty means the module defaults, which are sized for
  # this env (see modules/observability/variables.tf).
  alarm_thresholds = {}
}
