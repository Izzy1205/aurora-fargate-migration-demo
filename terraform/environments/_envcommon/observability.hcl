locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  mock_commands = get_env("MIGDEMO_MOCKS_ON_PLAN", "true") == "true" ? ["init", "validate", "plan"] : ["init", "validate"]
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}//layers/observability"
}

dependency "app" {
  config_path = "${get_terragrunt_dir()}/../app"

  mock_outputs = {
    alb_arn_suffix          = "app/migdemo-mock-alb/0000000000000000"
    target_group_arn_suffix = "targetgroup/migdemo-mock-app/0000000000000000"
    ecs_cluster_name        = "migdemo-mock-cluster"
    app_service_name        = "migdemo-mock-app"
    app_desired_count       = 2
    waf_web_acl_name        = "migdemo-mock-alb"
    payment_queue_name      = "migdemo-mock-payment-requests"
    payment_dlq_name        = "migdemo-mock-payment-requests-dlq"
  }
  mock_outputs_allowed_terraform_commands = local.mock_commands

  # Fills new outputs from mocks until app is re-applied.
  mock_outputs_merge_strategy_with_state = "shallow"
}

dependency "data" {
  config_path = "${get_terragrunt_dir()}/../data"

  mock_outputs = {
    aurora_cluster_identifier = "migdemo-mock-aurora"
  }
  mock_outputs_allowed_terraform_commands = local.mock_commands
}

inputs = {
  alb_arn_suffix          = dependency.app.outputs.alb_arn_suffix
  target_group_arn_suffix = dependency.app.outputs.target_group_arn_suffix
  ecs_cluster_name        = dependency.app.outputs.ecs_cluster_name
  ecs_service_name        = dependency.app.outputs.app_service_name
  app_desired_count       = dependency.app.outputs.app_desired_count
  waf_web_acl_name        = dependency.app.outputs.waf_web_acl_name
  payment_queue_name      = dependency.app.outputs.payment_queue_name
  payment_dlq_name        = dependency.app.outputs.payment_dlq_name

  aurora_cluster_identifier = dependency.data.outputs.aurora_cluster_identifier

  alarm_thresholds = local.env.alarm_thresholds

  alert_email = get_env("MIGDEMO_BUDGET_EMAIL")
}
