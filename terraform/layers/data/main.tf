# Layer 2 of 3: the Aurora Serverless v2 cluster, in the network layer's
# private subnets and behind its db security group. A writer, plus readers
# in the other AZ when aurora_instance_count is above 1.

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
