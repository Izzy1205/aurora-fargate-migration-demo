# Private DNS for the vault, and its security group. All rules are separate
# resources. The network module's groups have no inline rules, so adding
# rules to them from here changes nothing there.

data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${data.aws_region.current.region}.s3"
}

# Creates a Route 53 private hosted zone tied to the VPC. Names in it
# resolve only inside the VPC.
resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "${var.name_prefix}.internal"
  description = "Private service names for ${var.name_prefix}"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "vault" {
  name = "ssn-vault"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  # ECS reports task health (the container health check) to Cloud Map.
  health_check_custom_config {}

  # The AWS provider (6.x) doesn't read an empty health_check_custom_config
  # back into state, so every plan after create wants to replace this
  # service. AWS keeps the setting; ignore the phantom diff.
  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

resource "aws_security_group" "vault" {
  name        = local.name
  description = "SSN vault tasks: in from app tasks only, out to Aurora and AWS endpoints"
  vpc_id      = var.vpc_id
}

# In: the app tasks only.
resource "aws_vpc_security_group_ingress_rule" "vault_from_app" {
  security_group_id            = aws_security_group.vault.id
  description                  = "From app tasks"
  referenced_security_group_id = var.app_security_group_id
  from_port                    = var.port
  to_port                      = var.port
  ip_protocol                  = "tcp"
}

# The app group only allows the egress it lists, so it needs this to call
# the vault (PR 3).
resource "aws_vpc_security_group_egress_rule" "app_to_vault" {
  security_group_id            = var.app_security_group_id
  description                  = "To SSN vault tasks"
  referenced_security_group_id = aws_security_group.vault.id
  from_port                    = var.port
  to_port                      = var.port
  ip_protocol                  = "tcp"
}

# Out: Aurora, the interface endpoints (KMS, Secrets Manager, ECR, logs), and
# the S3 gateway endpoint for ECR image layers.
resource "aws_vpc_security_group_egress_rule" "vault_to_db" {
  security_group_id            = aws_security_group.vault.id
  description                  = "Postgres to Aurora"
  referenced_security_group_id = var.db_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_vault" {
  security_group_id            = var.db_security_group_id
  description                  = "Postgres from SSN vault tasks"
  referenced_security_group_id = aws_security_group.vault.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "vault_to_endpoints" {
  security_group_id            = aws_security_group.vault.id
  description                  = "HTTPS to interface endpoints"
  referenced_security_group_id = var.endpoints_security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_vault" {
  security_group_id            = var.endpoints_security_group_id
  description                  = "HTTPS from SSN vault tasks"
  referenced_security_group_id = aws_security_group.vault.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "vault_to_s3" {
  security_group_id = aws_security_group.vault.id
  description       = "HTTPS to S3 gateway endpoint (ECR layers)"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.s3.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
