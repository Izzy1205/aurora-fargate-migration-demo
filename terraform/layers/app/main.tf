data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Made by bootstrap. CI can only create roles that carry it.
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

  db_host             = var.db_host
  db_port             = var.db_port
  db_name             = var.db_name
  master_secret_arn   = var.master_secret_arn
  app_secret_arn      = var.app_secret_arn
  migrator_secret_arn = var.migrator_secret_arn
  app_username        = var.app_username
  migrator_username   = var.migrator_username

  app_environment = [
    { name = "PAYMENT_QUEUE_URL", value = module.queue.queue_url },
  ]
}

# Platform side only. The app team owns the consumer and idempotency.
module "queue" {
  source = "../../modules/queue"

  name_prefix       = local.name_prefix
  max_receive_count = var.payment_max_receive_count
}

resource "aws_iam_role_policy" "app_payment_queue" {
  name   = "payment-queue"
  role   = module.ecs.app_task_role_name
  policy = module.queue.task_policy_json
}

module "waf" {
  source = "../../modules/waf"

  name_prefix = local.name_prefix
  alb_arn     = module.ecs.alb_arn
  rate_limit  = var.waf_rate_limit
  count_only  = var.waf_count_only
}

module "budget" {
  source = "../../modules/budget"

  name_prefix = local.name_prefix
  limit_usd   = var.budget_limit_usd
  email       = var.budget_email
}
