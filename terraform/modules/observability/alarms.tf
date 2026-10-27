# Every alarm sends to the topic on ALARM and on OK, so the email that says
# something broke is followed by one that says it recovered.
#
# treat_missing_data, in short:
#   - ALB 5xx counts are only reported when they're above 0, so no data is
#     good news (notBreaching).
#   - Healthy hosts and the task count are expected to always report while
#     the service is up. No data there means no tasks (ECS stops sending
#     service metrics when nothing is RUNNING), so it counts as breaching.
#   - When Aurora auto-pauses it only reports CPU and ACU (both 0). The
#     memory and connection metrics stop, which is fine, so notBreaching.
#
# Metric names, namespaces and dimensions follow the AWS docs:
#   ALB:    AWS/ApplicationELB, LoadBalancer (+ TargetGroup)
#   ECS:    AWS/ECS, ClusterName + ServiceName (no Container Insights needed)
#   Aurora: AWS/RDS, DBClusterIdentifier

locals {
  lb_dims = { LoadBalancer = var.alb_arn_suffix }
  tg_dims = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  ecs_dims = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }
  db_dims = { DBClusterIdentifier = var.aurora_cluster_identifier }

  t = var.thresholds

  alarms = {
    alb-5xx = {
      description = "The ALB itself returned 5xx (no healthy target, timeout, bad gateway)."
      namespace   = "AWS/ApplicationELB"
      metric      = "HTTPCode_ELB_5XX_Count"
      statistic   = "Sum"
      dimensions  = local.lb_dims
      period      = 300
      evaluations = 1
      datapoints  = 1
      comparison  = "GreaterThanOrEqualToThreshold"
      threshold   = local.t.elb_5xx_count
      missing     = "notBreaching"
    }
    target-5xx = {
      description = "The app returned 5xx through the ALB."
      namespace   = "AWS/ApplicationELB"
      metric      = "HTTPCode_Target_5XX_Count"
      statistic   = "Sum"
      dimensions  = local.tg_dims
      period      = 300
      evaluations = 1
      datapoints  = 1
      comparison  = "GreaterThanOrEqualToThreshold"
      threshold   = local.t.target_5xx_count
      missing     = "notBreaching"
    }
    # AWS suggests Minimum over more than one datapoint for host counts, so
    # one task cycling during a deploy doesn't page anyone.
    unhealthy-hosts = {
      description = "At least one app task is failing the ALB health check (/health)."
      namespace   = "AWS/ApplicationELB"
      metric      = "UnHealthyHostCount"
      statistic   = "Minimum"
      dimensions  = local.tg_dims
      period      = 60
      evaluations = 3
      datapoints  = 2
      comparison  = "GreaterThanThreshold"
      threshold   = 0
      missing     = "notBreaching"
    }
    healthy-hosts-low = {
      description = "Fewer healthy app tasks behind the ALB than the service should run."
      namespace   = "AWS/ApplicationELB"
      metric      = "HealthyHostCount"
      statistic   = "Minimum"
      dimensions  = local.tg_dims
      period      = 60
      evaluations = 3
      datapoints  = 3
      comparison  = "LessThanThreshold"
      threshold   = var.desired_count
      missing     = "breaching"
    }
    # LiveTaskCount counts ACTIVATING, RUNNING and DEACTIVATING tasks. It's a
    # standard AWS/ECS metric, so it doesn't need Container Insights.
    ecs-tasks-low = {
      description = "The app service has fewer live tasks than it should."
      namespace   = "AWS/ECS"
      metric      = "LiveTaskCount"
      statistic   = "Minimum"
      dimensions  = local.ecs_dims
      period      = 60
      evaluations = 3
      datapoints  = 3
      comparison  = "LessThanThreshold"
      threshold   = var.desired_count
      missing     = "breaching"
    }
    ecs-cpu-high = {
      description = "App service CPU is high, averaged over its tasks."
      namespace   = "AWS/ECS"
      metric      = "CPUUtilization"
      statistic   = "Average"
      dimensions  = local.ecs_dims
      period      = 300
      evaluations = 2
      datapoints  = 2
      comparison  = "GreaterThanThreshold"
      threshold   = local.t.ecs_cpu_percent
      missing     = "notBreaching"
    }
    ecs-memory-high = {
      description = "App service memory is high, averaged over its tasks."
      namespace   = "AWS/ECS"
      metric      = "MemoryUtilization"
      statistic   = "Average"
      dimensions  = local.ecs_dims
      period      = 300
      evaluations = 2
      datapoints  = 2
      comparison  = "GreaterThanThreshold"
      threshold   = local.t.ecs_memory_percent
      missing     = "notBreaching"
    }
    # On Serverless v2 this is a percent of the CPU you'd have at max ACU.
    aurora-cpu-high = {
      description = "Aurora CPU is high, as a percent of what max ACU allows."
      namespace   = "AWS/RDS"
      metric      = "CPUUtilization"
      statistic   = "Average"
      dimensions  = local.db_dims
      period      = 300
      evaluations = 2
      datapoints  = 2
      comparison  = "GreaterThanThreshold"
      threshold   = local.t.aurora_cpu_percent
      missing     = "notBreaching"
    }
    aurora-acu-high = {
      description = "Aurora is at or near its max ACU and can't scale further."
      namespace   = "AWS/RDS"
      metric      = "ACUUtilization"
      statistic   = "Average"
      dimensions  = local.db_dims
      period      = 300
      evaluations = 3
      datapoints  = 3
      comparison  = "GreaterThanThreshold"
      threshold   = local.t.aurora_acu_percent
      missing     = "notBreaching"
    }
    # Serverless v2 keeps scaling up while it can, so this only gets low
    # once the cluster is already at max ACU.
    aurora-freeable-memory-low = {
      description = "Aurora is low on freeable memory, which on Serverless v2 means it's at max ACU."
      namespace   = "AWS/RDS"
      metric      = "FreeableMemory"
      statistic   = "Minimum"
      dimensions  = local.db_dims
      period      = 300
      evaluations = 2
      datapoints  = 2
      comparison  = "LessThanThreshold"
      threshold   = local.t.aurora_freeable_memory_bytes
      missing     = "notBreaching"
    }
    # The app opens one short connection per request and has no pool, so a
    # high count means a leak or a lot of traffic, not normal pooling.
    aurora-connections-high = {
      description = "Aurora has more open connections than expected."
      namespace   = "AWS/RDS"
      metric      = "DatabaseConnections"
      statistic   = "Maximum"
      dimensions  = local.db_dims
      period      = 300
      evaluations = 2
      datapoints  = 2
      comparison  = "GreaterThanThreshold"
      threshold   = local.t.aurora_connections
      missing     = "notBreaching"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name        = "${var.name_prefix}-${each.key}"
  alarm_description = "${each.value.description} See the README monitoring section."

  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  dimensions          = each.value.dimensions
  period              = each.value.period
  evaluation_periods  = each.value.evaluations
  datapoints_to_alarm = each.value.datapoints
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  treat_missing_data  = each.value.missing

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  # The topic policy has to exist first or the first ALARM or OK can't be
  # delivered.
  depends_on = [aws_sns_topic_policy.alarms]
}
