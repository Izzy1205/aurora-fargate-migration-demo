# Layer 4: alarms, the SNS topic they send to, and one dashboard. Runs after
# app. Nothing here changes how the other units behave; it only reads their
# names and IDs.

locals {
  name_prefix = "${var.project}-${var.environment}"
}

module "observability" {
  source = "../../modules/observability"

  name_prefix = local.name_prefix
  alert_email = var.alert_email

  alb_arn_suffix          = var.alb_arn_suffix
  target_group_arn_suffix = var.target_group_arn_suffix
  ecs_cluster_name        = var.ecs_cluster_name
  ecs_service_name        = var.ecs_service_name
  desired_count           = var.app_desired_count

  aurora_cluster_identifier = var.aurora_cluster_identifier

  thresholds = var.alarm_thresholds
}
