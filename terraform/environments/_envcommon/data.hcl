locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # Mocks let PRs plan before network exists. deploy.yml turns them off for real applies.
  mock_commands = get_env("MIGDEMO_MOCKS_ON_PLAN", "true") == "true" ? ["init", "validate", "plan"] : ["init", "validate"]
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}//layers/data"
}

dependency "network" {
  config_path = "${get_terragrunt_dir()}/../network"

  mock_outputs = {
    private_subnet_ids   = ["subnet-00000000000000001", "subnet-00000000000000002"]
    private_subnet_azs   = ["us-east-2a", "us-east-2b"]
    db_security_group_id = "sg-00000000000000003"
  }
  mock_outputs_allowed_terraform_commands = local.mock_commands

  # Lets a PR plan fill new outputs from mocks until network is re-applied.
  mock_outputs_merge_strategy_with_state = "shallow"
}

inputs = {
  private_subnet_ids   = dependency.network.outputs.private_subnet_ids
  private_subnet_azs   = dependency.network.outputs.private_subnet_azs
  db_security_group_id = dependency.network.outputs.db_security_group_id

  aurora_engine_version           = local.env.aurora_engine_version
  aurora_instance_count           = local.env.aurora_instance_count
  aurora_min_capacity             = local.env.aurora_min_capacity
  aurora_max_capacity             = local.env.aurora_max_capacity
  aurora_seconds_until_auto_pause = local.env.aurora_seconds_until_auto_pause
  db_name                         = local.env.db_name
  dr_region                       = local.env.dr_region
}
