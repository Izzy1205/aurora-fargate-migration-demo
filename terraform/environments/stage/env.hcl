# stage: NOT DEPLOYED. Inputs only, so the layout shows how a second
# environment would look. It validates and plans against mocks, nothing more.
# Before deploying it would need its own state bucket, a bootstrap apply with
# environment = "stage", its own GitHub environments, and an entry in the
# deploy.yml environment choice.

locals {
  environment = "stage"
  aws_region  = "us-east-2"

  state_bucket = "REPLACE-ME-stage-tfstate-bucket"

  vpc_cidr = "10.41.0.0/16"
  multi_az = true # interface endpoints in both AZs

  aurora_engine_version           = "16.9"
  aurora_min_capacity             = 0.5
  aurora_max_capacity             = 4
  aurora_seconds_until_auto_pause = 300 # ignored, min capacity is above 0
  db_name                         = "demo"

  app_desired_count = 2
  budget_limit_usd  = 25
}
