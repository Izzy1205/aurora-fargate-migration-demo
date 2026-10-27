# Observability unit (alarms, SNS topic, dashboard), shared by every
# environment. Reads names and IDs from app and data, changes nothing in them.

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # See data.hcl for why this switch exists.
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
  }
  mock_outputs_allowed_terraform_commands = local.mock_commands

  # The ARN suffix outputs are new. If app was applied before they existed,
  # a PR plan fills them from the mocks above instead of failing. Only for
  # the commands that allow mocks, so deploy.yml still sees real values.
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

  aurora_cluster_identifier = dependency.data.outputs.aurora_cluster_identifier

  alarm_thresholds = local.env.alarm_thresholds

  # Same inbox as the budget alerts.
  alert_email = get_env("MIGDEMO_BUDGET_EMAIL")
}
