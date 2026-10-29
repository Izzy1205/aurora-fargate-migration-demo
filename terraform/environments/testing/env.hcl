locals {
  environment     = "testing"
  aws_region      = "us-east-2"
  dr_region       = "us-west-2" # backup copies
  dr_copy_enabled = false       # org SCP blocks us-west-2

  # Bucket name stays out of the repo. Set TF_STATE_BUCKET.
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE-ME-tfstate-bucket")

  vpc_cidr = "10.40.0.0/16"
  multi_az = false # one AZ to halve endpoint cost

  aurora_engine_version           = "16.9"
  aurora_min_capacity             = 0
  aurora_max_capacity             = 2
  aurora_seconds_until_auto_pause = 300
  db_name                         = "demo"

  # Writer + reader so the demo can show a failover. Set to 1 for writer only.
  aurora_instance_count = 2

  app_desired_count = 2 # one per AZ
  budget_limit_usd  = 10

  # Blocking from day one. ALB only lets in my /32.
  waf_rate_limit = 1000
  waf_count_only = false

  alarm_thresholds = {}
}
