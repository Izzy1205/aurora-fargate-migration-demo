locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  mock_commands = get_env("MIGDEMO_MOCKS_ON_PLAN", "true") == "true" ? ["init", "validate", "plan"] : ["init", "validate"]
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}//layers/app"
}

dependency "network" {
  config_path = "${get_terragrunt_dir()}/../network"

  mock_outputs = {
    vpc_id                      = "vpc-00000000000000001"
    public_subnet_ids           = ["subnet-00000000000000011", "subnet-00000000000000012"]
    private_subnet_ids          = ["subnet-00000000000000001", "subnet-00000000000000002"]
    alb_security_group_id       = "sg-00000000000000001"
    app_security_group_id       = "sg-00000000000000002"
    migration_security_group_id = "sg-00000000000000004"
  }
  mock_outputs_allowed_terraform_commands = local.mock_commands
}

dependency "data" {
  config_path = "${get_terragrunt_dir()}/../data"

  mock_outputs = {
    endpoint            = "mock-aurora.cluster-000000000000.us-east-2.rds.amazonaws.com"
    port                = 5432
    db_name             = "demo"
    master_secret_arn   = "arn:aws:secretsmanager:us-east-2:000000000000:secret:rds!cluster-mock-000000"
    app_secret_arn      = "arn:aws:secretsmanager:us-east-2:000000000000:secret:migdemo-mock/db/app-000000"
    migrator_secret_arn = "arn:aws:secretsmanager:us-east-2:000000000000:secret:migdemo-mock/db/migrator-000000"
    app_username        = "app_user"
    migrator_username   = "migrator"
  }
  mock_outputs_allowed_terraform_commands = local.mock_commands
}

inputs = {
  app_port = 8000 # keep in step with network.hcl

  vpc_id                      = dependency.network.outputs.vpc_id
  public_subnet_ids           = dependency.network.outputs.public_subnet_ids
  private_subnet_ids          = dependency.network.outputs.private_subnet_ids
  alb_security_group_id       = dependency.network.outputs.alb_security_group_id
  app_security_group_id       = dependency.network.outputs.app_security_group_id
  migration_security_group_id = dependency.network.outputs.migration_security_group_id

  db_host             = dependency.data.outputs.endpoint
  db_port             = dependency.data.outputs.port
  db_name             = dependency.data.outputs.db_name
  master_secret_arn   = dependency.data.outputs.master_secret_arn
  app_secret_arn      = dependency.data.outputs.app_secret_arn
  migrator_secret_arn = dependency.data.outputs.migrator_secret_arn
  app_username        = dependency.data.outputs.app_username
  migrator_username   = dependency.data.outputs.migrator_username

  app_desired_count = local.env.app_desired_count
  budget_limit_usd  = local.env.budget_limit_usd

  waf_rate_limit = local.env.waf_rate_limit
  waf_count_only = local.env.waf_count_only

  budget_email = get_env("MIGDEMO_BUDGET_EMAIL")
}
