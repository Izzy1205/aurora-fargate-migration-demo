# Alarms notify on ALARM and OK. Missing data is breaching only where it means no tasks.

locals {
  lb_dims = { LoadBalancer = var.alb_arn_suffix }
  tg_dims = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  ecs_dims = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }
  db_dims    = { DBClusterIdentifier = var.aurora_cluster_identifier }
  queue_dims = { QueueName = var.payment_queue_name }
  dlq_dims   = { QueueName = var.payment_dlq_name }

  # By role, not instance, since roles swap on failover.
  db_reader_dims = { DBClusterIdentifier = var.aurora_cluster_identifier, Role = "READER" }

  waf_dims = {
    WebACL = var.waf_web_acl_name
    Region = data.aws_region.current.region
    Rule   = "ALL"
  }

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
    # Minimum over a few points so one task cycling in a deploy doesn't page.
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
    # Percent of CPU at max ACU.
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
    # Only gets low once the cluster is already at max ACU.
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
    # No pool, so a high count means a leak or a traffic spike.
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
    # No readers or a paused cluster sends no data, which is fine.
    aurora-replica-lag-high = {
      description = "An Aurora reader is lagging behind the writer."
      namespace   = "AWS/RDS"
      metric      = "AuroraReplicaLag"
      statistic   = "Maximum"
      dimensions  = local.db_reader_dims
      period      = 60
      evaluations = 5
      datapoints  = 3
      comparison  = "GreaterThanThreshold"
      threshold   = local.t.aurora_replica_lag_ms
      missing     = "notBreaching"
    }
    # Stays OK in count-only mode. Watch CountedRequests instead.
    waf-blocked-spike = {
      description = "The WAF blocked a lot of requests (rate limit or managed rules). Either an attack or a false positive."
      namespace   = "AWS/WAFV2"
      metric      = "BlockedRequests"
      statistic   = "Sum"
      dimensions  = local.waf_dims
      period      = 300
      evaluations = 1
      datapoints  = 1
      comparison  = "GreaterThanOrEqualToThreshold"
      threshold   = local.t.waf_blocked_requests
      missing     = "notBreaching"
    }
    # Anything here failed every retry.
    payment-dlq-not-empty = {
      description = "A payment request failed every retry and is in the dead letter queue. Look at it, fix the cause, then redrive."
      namespace   = "AWS/SQS"
      metric      = "ApproximateNumberOfMessagesVisible"
      statistic   = "Maximum"
      dimensions  = local.dlq_dims
      period      = 300
      evaluations = 1
      datapoints  = 1
      comparison  = "GreaterThanThreshold"
      threshold   = 0
      missing     = "notBreaching"
    }
    # Consumer is down, stuck or too slow.
    payment-queue-oldest-message = {
      description = "The oldest payment request has waited too long. The consumer is down or falling behind."
      namespace   = "AWS/SQS"
      metric      = "ApproximateAgeOfOldestMessage"
      statistic   = "Maximum"
      dimensions  = local.queue_dims
      period      = 300
      evaluations = 2
      datapoints  = 2
      comparison  = "GreaterThanThreshold"
      threshold   = local.t.queue_oldest_message_seconds
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

  # Topic policy first, or the first notification can't be delivered.
  depends_on = [aws_sns_topic_policy.alarms]
}
