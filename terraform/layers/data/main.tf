# Layer 2 of 3: the Aurora Serverless v2 cluster, in the network layer's
# private subnets and behind its db security group. A writer, plus readers
# in the other AZ when aurora_instance_count is above 1. Daily backups are
# copied to var.dr_region so the data outlives the home region.

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

# Here and not in a layer of its own: the backups belong to the cluster,
# and a new layer would mean new state, new pipeline steps and a new
# teardown step. The DR region comes in through the aws.dr provider.
module "backup" {
  source = "../../modules/backup"

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  name_prefix      = local.name_prefix
  cluster_arn      = module.database.cluster_arn
  backup_role_name = "${local.name_prefix}-backup"
}

# A copy in the same region would not survive losing it.
check "dr_region_differs" {
  assert {
    condition     = module.backup.dr_region != data.aws_region.home.region
    error_message = "dr_region is the same as the home region. The copies would go down with it."
  }
}

data "aws_region" "home" {}
