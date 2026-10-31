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
#   Aurora: AWS/RDS, DBClusterIdentifier (+ Role for reader-only metrics)
#   WAF:    AWS/WAFV2, WebACL + Region + Rule (Rule = ALL for the whole ACL)
#   SQS:    AWS/SQS, QueueName
#   Vault:  MigDemo/SsnVault, NamePrefix (the app's own EMF log lines, see
#           app/src/demo_app/ssn_vault_client.py)

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

  # The SSN vault service (modules/ssn_vault_service) runs in the same
  # cluster as the app and is always named "<name_prefix>-ssn-vault".
  vault_ecs_dims = {
    ClusterName = var.ecs_cluster_name
    ServiceName = "${var.name_prefix}-ssn-vault"
  }

  # Must match _emf() in ssn_vault_client.py exactly: one dimension,
  # NamePrefix, set to the environment name prefix (migdemo-testing).
  vault_emf_dims = { NamePrefix = var.name_prefix }

  # Every instance that's a reader right now, whatever its name. After a
  # failover the roles swap, so a per-instance alarm would watch the wrong one.
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
    # Aurora replicas usually trail the writer by tens of milliseconds. A
    # reader that falls seconds behind serves stale reads and would lose
    # those seconds of writes if it were promoted. No readers, or a paused
    # cluster, sends no data, which is fine.
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
    # WAF only reports BlockedRequests when it blocks something, so no data
    # is good news. In count-only mode nothing is blocked and this stays OK;
    # watch CountedRequests on the dashboard instead.
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
    # Any message in the DLQ is a payment request that failed every retry.
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
    # Messages sitting unread: the consumer is down, stuck or too slow.
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
    # The app answers 503 on /ssn and logs ssn_vault_unavailable when the
    # vault can't be reached (DNS, refused, timeout) or answers 5xx. The
    # metric only exists when that happens, so no data is good news.
    # A task that can't work out its name prefix logs NamePrefix "unknown"
    # instead; target-5xx still catches those 503s.
    ssn-vault-unavailable = {
      description = "The app couldn't use the SSN vault and answered 503 on /ssn. Check the vault tasks, its log group /ecs/<name_prefix>/ssn-vault, its security group and Cloud Map."
      namespace   = "MigDemo/SsnVault"
      metric      = "ssn_vault_unavailable"
      statistic   = "Sum"
      dimensions  = local.vault_emf_dims
      period      = 300
      evaluations = 1
      datapoints  = 1
      comparison  = "GreaterThanOrEqualToThreshold"
      threshold   = 1
      missing     = "notBreaching"
    }
    # Same metric as ecs-tasks-low, for the vault service. The floor is 1,
    # not ssn_vault_desired_count, so this needs no new inputs: every
    # environment runs at least one vault task. Deploys keep 100% healthy,
    # so a rollout doesn't dip below it. No data means no tasks.
    ssn-vault-tasks-low = {
      description = "The SSN vault service has no live tasks, so every /ssn request answers 503."
      namespace   = "AWS/ECS"
      metric      = "LiveTaskCount"
      statistic   = "Minimum"
      dimensions  = local.vault_ecs_dims
      period      = 60
      evaluations = 3
      datapoints  = 3
      comparison  = "LessThanThreshold"
      threshold   = 1
      missing     = "breaching"
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
