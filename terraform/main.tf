locals {
  name_prefix = "${var.project}-${var.environment}"
  app_port    = 8000
}

module "network" {
  source = "./modules/network"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  app_port            = local.app_port
  alb_ingress_cidrs   = var.alb_ingress_cidrs
  single_az_endpoints = var.single_az_endpoints
}

module "database" {
  source = "./modules/database"

  name_prefix              = local.name_prefix
  subnet_ids               = module.network.private_subnet_ids
  security_group_id        = module.network.db_security_group_id
  engine_version           = var.aurora_engine_version
  min_capacity             = var.aurora_min_capacity
  max_capacity             = var.aurora_max_capacity
  seconds_until_auto_pause = var.aurora_seconds_until_auto_pause
  db_name                  = var.db_name
}

module "registry" {
  source = "./modules/registry"

  name_prefix = local.name_prefix
}

module "ecs" {
  source = "./modules/ecs"

  name_prefix           = local.name_prefix
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id
  app_security_group_id = module.network.app_security_group_id
  app_port              = local.app_port

  app_image                = "${module.registry.repository_urls["app"]}:${var.app_image_tag}"
  migration_image          = "${module.registry.repository_urls["migrate"]}:${var.app_image_tag}"
  app_repository_arn       = module.registry.repository_arns["app"]
  migration_repository_arn = module.registry.repository_arns["migrate"]

  db_host       = module.database.endpoint
  db_port       = module.database.port
  db_name       = module.database.db_name
  db_secret_arn = module.database.master_user_secret_arn
}

module "budget" {
  source = "./modules/budget"

  name_prefix = local.name_prefix
  limit_usd   = var.budget_limit_usd
  email       = var.budget_email
}
