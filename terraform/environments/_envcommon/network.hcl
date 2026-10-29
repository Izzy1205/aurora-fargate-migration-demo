locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  # Double slash copies all of terraform/ so ../../modules still resolves.
  source = "${dirname(find_in_parent_folders("root.hcl"))}//layers/network"
}

inputs = {
  app_port            = 8000 # keep in step with app.hcl
  vpc_cidr            = local.env.vpc_cidr
  single_az_endpoints = !local.env.multi_az

  # JSON list, e.g. ["203.0.113.10/32"]
  alb_ingress_cidrs = jsondecode(get_env("MIGDEMO_ALB_INGRESS_CIDRS"))
}
