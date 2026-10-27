# Layer 1 of 3: VPC, subnets, endpoints, flow logs and every security group.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Created by terraform/bootstrap. The terraform role can only create roles
  # that carry it, so every role in this stack gets it.
  permissions_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.name_prefix}-workload-boundary"
}

module "network" {
  source = "../../modules/network"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  app_port            = var.app_port
  alb_ingress_cidrs   = var.alb_ingress_cidrs
  single_az_endpoints = var.single_az_endpoints

  permissions_boundary_arn = local.permissions_boundary_arn
}
