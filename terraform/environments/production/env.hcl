# Not deployed. Inputs only, same as stage.

locals {
  environment = "production"
  aws_region  = "us-east-2"
  dr_region   = "us-west-2" # backup copies

  state_bucket = "REPLACE-ME-production-tfstate-bucket"

  vpc_cidr = "10.42.0.0/16"
  multi_az = true

  aurora_engine_version           = "16.9"
  aurora_instance_count           = 2 # writer + reader
  aurora_min_capacity             = 1
  aurora_max_capacity             = 8
  aurora_seconds_until_auto_pause = 300 # ignored, min capacity is above 0
  db_name                         = "demo"

  app_desired_count = 4
  budget_limit_usd  = 50

  # Count-only for first rollout. Higher limit for users behind shared NAT.
  waf_rate_limit = 2000
  waf_count_only = true

  # max 8 ACU allows well over 1,000 connections.
  alarm_thresholds = {
    elb_5xx_count                = 20
    target_5xx_count             = 20
    aurora_connections           = 800
    waf_blocked_requests         = 500
    queue_oldest_message_seconds = 600
    slo_availability_percent     = 99.9
    latency_p95_seconds          = 1
  }
}
