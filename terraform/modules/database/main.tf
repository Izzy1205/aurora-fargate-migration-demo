locals {
  cluster_identifier = "${var.name_prefix}-aurora"

  # Every subnet AZ except the writer's. Known at plan time on a live stack;
  # on a fresh one it waits for the writer to exist.
  reader_azs = [
    for az in distinct(var.availability_zones) : az
    if az != aws_rds_cluster_instance.writer.availability_zone
  ]
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.subnet_ids
}

# RDS would create this log group itself with no expiry. Creating it here
# first gives it a retention and lets terraform destroy remove it.
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/cluster/${local.cluster_identifier}/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_rds_cluster" "this" {
  # The plan is modules/backup, which the data layer points at this
  # cluster's ARN. checkov can't follow an output from one module into
  # another, so it can't see the link.
  #checkov:skip=CKV2_AWS_8:Backed up by modules/backup, selected by ARN in layers/data
  cluster_identifier = local.cluster_identifier
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned" # Serverless v2 runs under the provisioned engine mode
  engine_version     = var.engine_version
  database_name      = var.db_name
  master_username    = var.master_username

  # RDS generates the password and keeps it in a Secrets Manager secret it
  # owns (named rds!cluster-...). It never appears in Terraform code or state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]

  storage_encrypted                   = true
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  copy_tags_to_snapshot               = true
  backup_retention_period             = var.backup_retention_period

  # Demo only, it's torn down the same day. Real stacks want deletion
  # protection and a final snapshot.
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true
  apply_immediately        = true

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
    # Pause after this many idle seconds. Resuming takes roughly 15 seconds.
    seconds_until_auto_pause = var.min_capacity == 0 ? var.seconds_until_auto_pause : null
  }

  depends_on = [aws_cloudwatch_log_group.postgresql]
}

# The first instance, created as the writer. Serverless v2 has to use
# db.serverless. Its AZ is left to RDS, as it always was: setting one now
# would replace the live writer. After a failover this instance may be a
# reader; the Terraform name only says which one was created first.
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

# Readers, one per instance past the first. Each goes in a private subnet AZ
# the writer isn't in, so losing one AZ leaves an instance to promote. That
# is usually done in under 60 seconds, where a cluster with only a writer has to wait
# for RDS to rebuild it (usually under 10 minutes, per the Aurora HA docs).
#
# Promotion tier 1 puts the reader first in line for failover and ties its
# capacity to the writer's, so it's already sized to take over. It also
# pauses and resumes with the writer when min capacity is 0, so an idle
# testing stack still costs nothing for compute.
#
# Referencing the writer's AZ also makes Terraform create the writer first.
# That matters: Aurora makes whichever instance comes up first the writer.
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
