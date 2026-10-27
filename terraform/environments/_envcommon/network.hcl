# Network unit, shared by every environment. The unit folder only includes
# this file and root.hcl; the values come from that environment's env.hcl.

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  # The double slash copies all of terraform/ into the cache, so the layer's
  # ../../modules paths still resolve there.
  source = "${dirname(find_in_parent_folders("root.hcl"))}//layers/network"
}

inputs = {
  app_port            = 8000 # keep in step with app.hcl
  vpc_cidr            = local.env.vpc_cidr
  single_az_endpoints = !local.env.multi_az

  # JSON list, for example ["203.0.113.10/32"]. Same value the flat stack
  # took from TF_VAR_alb_ingress_cidrs.
  alb_ingress_cidrs = jsondecode(get_env("MIGDEMO_ALB_INGRESS_CIDRS"))
}
