# production: NOT DEPLOYED. Inputs only, same as stage. See stage/env.hcl for
# what deploying it would take. The README's production section lists the
# demo trade-offs (HTTP ALB, no deletion protection and so on) that would
# also have to change first.

locals {
  environment = "production"
  aws_region  = "us-east-2"

  state_bucket = "REPLACE-ME-production-tfstate-bucket"

  vpc_cidr = "10.42.0.0/16"
  multi_az = true # interface endpoints in both AZs

  aurora_engine_version           = "16.9"
  aurora_instance_count           = 2 # writer plus a reader in the other AZ
  aurora_min_capacity             = 1
  aurora_max_capacity             = 8
  aurora_seconds_until_auto_pause = 300 # ignored, min capacity is above 0
  db_name                         = "demo"

  app_desired_count = 4
  budget_limit_usd  = 50

  # WAF on the ALB. Count only for the first rollout, same as stage. More
  # users behind shared NAT addresses, so a higher per-IP limit.
  waf_rate_limit = 2000
  waf_count_only = true

  # Alarm thresholds, on top of the module defaults. More traffic means more
  # stray 5xx, and max 8 ACU allows well over 1,000 Postgres connections.
  alarm_thresholds = {
    elb_5xx_count      = 20
    target_5xx_count   = 20
    aurora_connections = 800
    # More users means more junk traffic hitting the managed rules.
    waf_blocked_requests = 500
    # Bigger backlog is normal at peak; still well under the retention.
    queue_oldest_message_seconds = 600
    # Same as the module defaults, written out so the promise is easy to
    # find. See modules/observability/slo.tf for what they drive.
    slo_availability_percent = 99.9
    latency_p95_seconds      = 1
  }
}
