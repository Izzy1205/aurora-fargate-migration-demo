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
  aurora_min_capacity             = 1
  aurora_max_capacity             = 8
  aurora_seconds_until_auto_pause = 300 # ignored, min capacity is above 0
  db_name                         = "demo"

  app_desired_count = 4
  budget_limit_usd  = 50
}
