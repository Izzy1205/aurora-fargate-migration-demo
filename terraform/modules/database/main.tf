locals {
  cluster_identifier = "${var.name_prefix}-aurora"

  # Every subnet AZ except the writer's.
  reader_azs = [
    for az in distinct(var.availability_zones) : az
    if az != aws_rds_cluster_instance.writer.availability_zone
  ]
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.subnet_ids
}

# Created here so it gets a retention and is removed on destroy.
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/cluster/${local.cluster_identifier}/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_rds_cluster" "this" {
  # checkov can't follow the ARN across modules.
  #checkov:skip=CKV2_AWS_8:Backed up by modules/backup, selected by ARN in layers/data
  cluster_identifier = local.cluster_identifier
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  engine_version     = var.engine_version
  database_name      = var.db_name
  master_username    = var.master_username

  # RDS owns the password in Secrets Manager. Never in TF state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]

  storage_encrypted                   = true
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  copy_tags_to_snapshot               = true
  backup_retention_period             = var.backup_retention_period

  # Demo only, torn down the same day.
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true
  apply_immediately        = true

  serverlessv2_scaling_configuration {
    min_capacity             = var.min_capacity
    max_capacity             = var.max_capacity
    seconds_until_auto_pause = var.min_capacity == 0 ? var.seconds_until_auto_pause : null
  }

  depends_on = [aws_cloudwatch_log_group.postgresql]
}

# No AZ on purpose: setting one would replace the live writer.
resource "aws_rds_cluster_instance" "writer" {
  identifier           = "${local.cluster_identifier}-writer"
  cluster_identifier   = aws_rds_cluster.this.id
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.this.engine
  engine_version       = aws_rds_cluster.this.engine_version
  db_subnet_group_name = aws_db_subnet_group.this.name
  publicly_accessible  = false

  auto_minor_version_upgrade = true
  apply_immediately          = true
}

# One reader per extra instance, in an AZ the writer isn't in.
# Using the writer's AZ also orders creation. Aurora makes the first instance up the writer.
resource "aws_rds_cluster_instance" "reader" {
  count = var.instance_count - 1

  identifier           = "${local.cluster_identifier}-reader-${count.index + 1}"
  cluster_identifier   = aws_rds_cluster.this.id
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.this.engine
  engine_version       = aws_rds_cluster.this.engine_version
  db_subnet_group_name = aws_db_subnet_group.this.name
  publicly_accessible  = false
  promotion_tier       = 1

  availability_zone = local.reader_azs[count.index % length(local.reader_azs)]

  auto_minor_version_upgrade = true
  apply_immediately          = true
}
