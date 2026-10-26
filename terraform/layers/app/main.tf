# Layer 3 of 3: ECR repos, the ECS cluster, ALB, task definitions and service,
# plus the cost budget. Network and database values come in as variables from
# the other two units.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Created by terraform/bootstrap. The terraform role can only create roles
  # that carry it, so every role in this stack gets it.
  permissions_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.name_prefix}-workload-boundary"
}

module "registry" {
  source = "../../modules/registry"

  name_prefix = local.name_prefix
}

module "ecs" {
  source = "../../modules/ecs"

  name_prefix           = local.name_prefix
  vpc_id                = var.vpc_id
  public_subnet_ids     = var.public_subnet_ids
  private_subnet_ids    = var.private_subnet_ids
  alb_security_group_id = var.alb_security_group_id
  app_security_group_id = var.app_security_group_id
  app_port              = var.app_port

  permissions_boundary_arn = local.permissions_boundary_arn

  app_image                = "${module.registry.repository_urls["app"]}:${var.app_image_tag}"
  migration_image          = "${module.registry.repository_urls["migrate"]}:${var.app_image_tag}"
  app_repository_arn       = module.registry.repository_arns["app"]
  migration_repository_arn = module.registry.repository_arns["migrate"]

  db_host       = var.db_host
  db_port       = var.db_port
  db_name       = var.db_name
  db_secret_arn = var.db_secret_arn
}

module "budget" {
  source = "../../modules/budget"

  name_prefix = local.name_prefix
  limit_usd   = var.budget_limit_usd
  email       = var.budget_email
}
