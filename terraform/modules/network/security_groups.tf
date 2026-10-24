# All security groups live here so the database and ECS modules can reference
# each other's groups without a dependency cycle.

data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${data.aws_region.current.region}.s3"
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "ALB: HTTP in from allowed CIDRs, out to app tasks only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app"
  description = "App tasks: in from ALB, out to Aurora and AWS endpoints"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "migration" {
  name        = "${var.name_prefix}-migration"
  description = "Flyway task: no inbound, out to Aurora and AWS endpoints"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "Aurora: 5432 in from app and migration tasks only, no outbound"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-endpoints"
  description = "Interface endpoints: 443 in from app and migration tasks"
  vpc_id      = aws_vpc.this.id
}

# ALB
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from allowed CIDR"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To app tasks"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# App
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "From ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# Shared outbound rules for the two task groups.
locals {
  task_sgs = {
    app       = aws_security_group.app.id
    migration = aws_security_group.migration.id
  }
}

resource "aws_vpc_security_group_egress_rule" "task_to_db" {
  for_each = local.task_sgs

  security_group_id            = each.value
  description                  = "Postgres to Aurora"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_to_endpoints" {
  for_each = local.task_sgs

  security_group_id            = each.value
  description                  = "HTTPS to interface endpoints"
  referenced_security_group_id = aws_security_group.endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_to_s3" {
  for_each = local.task_sgs

  security_group_id = each.value
  description       = "HTTPS to S3 gateway endpoint (ECR layers)"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.s3.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Database
resource "aws_vpc_security_group_ingress_rule" "db_from_task" {
  for_each = local.task_sgs

  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from ${each.key} tasks"
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# Endpoints
resource "aws_vpc_security_group_ingress_rule" "endpoints_from_task" {
  for_each = local.task_sgs

  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from ${each.key} tasks"
  referenced_security_group_id = each.value
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}
