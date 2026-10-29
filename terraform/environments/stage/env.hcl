# Not deployed. Inputs only, so the layout shows what a second env looks like.

locals {
  environment     = "stage"
  aws_region      = "us-east-2"
  dr_region       = "us-west-2" # backup copies
  dr_copy_enabled = false       # org SCP blocks us-west-2

  state_bucket = "REPLACE-ME-stage-tfstate-bucket"

  vpc_cidr = "10.41.0.0/16"
  multi_az = true

  aurora_engine_version           = "16.9"
  aurora_instance_count           = 2 # writer + reader
  aurora_min_capacity             = 0.5
  aurora_max_capacity             = 4
  aurora_seconds_until_auto_pause = 300 # ignored, min capacity is above 0
  db_name                         = "demo"

  app_desired_count = 2
  budget_limit_usd  = 25

  # Count-only for first rollout. Flip to false after checking WAF logs.
  waf_rate_limit = 1000
  waf_count_only = true

  # Max 4 ACU is about 800 connections, so alert at half.
  alarm_thresholds = {
    aurora_connections           = 400
    waf_blocked_requests         = 200
    queue_oldest_message_seconds = 600
  }
}
