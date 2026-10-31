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

  # Also from terraform/bootstrap. Only the SSN vault roles may carry it.
  vault_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${local.name_prefix}-ssn-vault-boundary"
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

# Key, HMAC pepper and DB access for the SSN token service. Only the vault
# service (below) uses them. Nothing here touches a task definition: the
# vault finds the key by its alias (alias/<name_prefix>-ssn), reads the
# pepper secret by name, and signs in to Aurora as ssn_vault_login with an
# IAM auth token, all with its own task role. Changing a task definition's
# env or secrets would replace it, and the deploy delete gate blocks
# replaces.
#
# The cluster resource ID (for the rds-db:connect ARN) is read here, not passed
# from the data layer as an output: a new output only exists in state after
# the data layer is applied, so PR plans (which never apply) couldn't see it.
data "aws_rds_cluster" "this" {
  cluster_identifier = "${local.name_prefix}-aurora"
}

module "ssn_vault" {
  source = "../../modules/ssn_vault"

  name_prefix            = local.name_prefix
  db_cluster_resource_id = data.aws_rds_cluster.this.cluster_resource_id
}

# The app only forwards /ssn to the vault service, so its task role gets
# explicit denies on the SSN key, the <name_prefix>/ssn/ secrets and the
# vault login. Same resource and name as the allow policy it replaces, so
# this is an in-place update (a new name would replace it, and the delete
# gate blocks that).
resource "aws_iam_role_policy" "app_ssn_vault" {
  name   = "ssn-vault"
  role   = module.ecs.app_task_role_name
  policy = module.ssn_vault.app_deny_policy_json
}

# The token service as its own ECS service (same image, vault-only mode),
# reachable only from the app tasks by private DNS. The app's /ssn routes
# forward here and answer 503 if it can't answer.
#
# The endpoint and Aurora security groups are looked up by name, not passed
# from the network unit: like the cluster above, a new network output would
# only exist after the network unit is applied, so PR plans couldn't see it.
data "aws_security_group" "endpoints" {
  vpc_id = var.vpc_id
  name   = "${local.name_prefix}-endpoints"
}

data "aws_security_group" "db" {
  vpc_id = var.vpc_id
  name   = "${local.name_prefix}-db"
}

module "ssn_vault_service" {
  source = "../../modules/ssn_vault_service"

  name_prefix                 = local.name_prefix
  vpc_id                      = var.vpc_id
  private_subnet_ids          = var.private_subnet_ids
  cluster_arn                 = module.ecs.cluster_arn
  app_security_group_id       = var.app_security_group_id
  endpoints_security_group_id = data.aws_security_group.endpoints.id
  db_security_group_id        = data.aws_security_group.db.id

  permissions_boundary_arn = local.vault_boundary_arn
  task_policy_json         = module.ssn_vault.task_policy_json

  image          = "${module.registry.repository_urls["app"]}:${var.app_image_tag}"
  repository_arn = module.registry.repository_arns["app"]

  db_host = var.db_host
  db_port = var.db_port
  db_name = var.db_name
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
