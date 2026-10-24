locals {
  cluster_identifier = "${var.name_prefix}-aurora"
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
  backup_retention_period             = 1

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

# One writer, no readers. Serverless v2 has to use db.serverless.
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
