# Deployed only by promote.yml, from an image already running in testing.

locals {
  environment     = "stage"
  aws_region      = "us-east-2"
  dr_region       = "us-west-2" # backup copies
  dr_copy_enabled = false       # org SCP blocks us-west-2

  # Same bucket as testing, keys split by env (root.hcl). Set TF_STATE_BUCKET.
  state_bucket = get_env("TF_STATE_BUCKET", "REPLACE-ME-tfstate-bucket")

  vpc_cidr = "10.41.0.0/16"
  multi_az = true

  aurora_engine_version           = "16.9"
  aurora_instance_count           = 2 # writer + reader
  aurora_min_capacity             = 0.5
  aurora_max_capacity             = 4
  aurora_seconds_until_auto_pause = 300 # ignored, min capacity is above 0
  db_name                         = "demo"

  app_desired_count       = 2
  ssn_vault_desired_count = 2 # one per AZ
  budget_limit_usd        = 25

  # Blocking, same as testing. waf_count_only = true counts instead, for a
  # first rollout of new rules; read the WAF logs, then set it back.
  waf_rate_limit = 1000
  waf_count_only = false

  # The WAF answers 403 to any country not listed. [] turns the rule off.
  waf_geo_allow_countries = ["US"]

  # HTTPS cert. Null for both means a self-signed cert (curl -k). For a real
  # one, set a name in a public Route 53 zone you own, for example
  # domain_name = "stage.example.com" and route53_zone_id = "Z0123456789ABC".
  domain_name     = null
  route53_zone_id = null

  # Max 4 ACU is about 800 connections, so alert at half.
  alarm_thresholds = {
    aurora_connections           = 400
    waf_blocked_requests         = 200
    queue_oldest_message_seconds = 600
  }
}
