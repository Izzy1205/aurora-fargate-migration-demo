locals {
  name_prefix = "${var.project}-${var.environment}"
}

module "database" {
  source = "../../modules/database"

  name_prefix              = local.name_prefix
  subnet_ids               = var.private_subnet_ids
  availability_zones       = var.private_subnet_azs
  instance_count           = var.aurora_instance_count
  security_group_id        = var.db_security_group_id
  engine_version           = var.aurora_engine_version
  min_capacity             = var.aurora_min_capacity
  max_capacity             = var.aurora_max_capacity
  seconds_until_auto_pause = var.aurora_seconds_until_auto_pause
  db_name                  = var.db_name
}

# Lives with the cluster to avoid a new layer, state and pipeline step.
module "backup" {
  source = "../../modules/backup"

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  name_prefix      = local.name_prefix
  cluster_arn      = module.database.cluster_arn
  backup_role_name = "${local.name_prefix}-backup"
  dr_copy_enabled  = var.dr_copy_enabled
}

check "dr_region_differs" {
  assert {
    condition     = !var.dr_copy_enabled || module.backup.dr_region != data.aws_region.home.region
    error_message = "dr_region is the same as the home region. The copies would go down with it."
  }
}

data "aws_region" "home" {}
