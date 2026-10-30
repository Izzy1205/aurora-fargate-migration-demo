# Layer 3: ECR repos, the ECS cluster, ALB and its WAF, task definitions and
# service, the payment queue, plus the cost budget. Network and database
# values come in as variables from the other two units.

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

# Payment requests queue and its DLQ. The app team writes the consumer and
# the idempotency handling; this is the platform side.
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

# Key, HMAC pepper and DB access for the SSN token service. Nothing here
# touches the task definition: the app finds the key by its alias
# (alias/<name_prefix>-ssn), reads the pepper secret by name, and signs in to
# Aurora as ssn_vault_login with an IAM auth token, all with the task role.
# Changing the task definition's env or secrets would replace it, and the
# deploy delete gate blocks replaces.
module "ssn_vault" {
  source = "../../modules/ssn_vault"

  name_prefix            = local.name_prefix
  db_cluster_resource_id = var.db_cluster_resource_id
}

resource "aws_iam_role_policy" "app_ssn_vault" {
  name   = "ssn-vault"
  role   = module.ecs.app_task_role_name
  policy = module.ssn_vault.task_policy_json
}

# Web ACL on the ALB. Lives in this unit so it's created and destroyed with
# the ALB it protects.
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
