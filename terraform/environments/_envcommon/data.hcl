# Data unit (Aurora), shared by every environment.

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # Mock outputs let validate and plan run before the network unit has ever
  # been applied, which is the normal case for a PR or a local plan on a
  # torn down stack. deploy.yml sets MIGDEMO_MOCKS_ON_PLAN=false so a plan it
  # is going to apply can only ever see real outputs.
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

  # private_subnet_azs is a new output. Until network has been applied with
  # it, a PR plan fills it from the mocks instead of failing. deploy.yml
  # applies network before data, so a real deploy sees the real value.
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
}
