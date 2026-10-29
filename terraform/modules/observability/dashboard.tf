# One dashboard with the same metrics the alarms watch, plus the SLO
# widgets (SLI, burn rate, p95 latency) at the bottom. The first three
# dashboards in an account are free, after that it's $3 a month.

locals {
  region = data.aws_region.current.region

  lb    = var.alb_arn_suffix
  tg    = var.target_group_arn_suffix
  ecs   = ["ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name]
  db    = ["DBClusterIdentifier", var.aurora_cluster_identifier]
  queue = ["QueueName", var.payment_queue_name]
  dlq   = ["QueueName", var.payment_dlq_name]
  waf   = ["WebACL", var.waf_web_acl_name, "Region", local.region, "Rule", "ALL"]

  widgets = [
    {
      title = "ALB 5xx (sum per 5 min)"
      stat  = "Sum"
      metrics = [
        ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.lb],
        ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.lb, "TargetGroup", local.tg],
      ]
    },
    {
      title = "Targets (healthy / unhealthy)"
      stat  = "Minimum"
      metrics = [
        ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.lb, "TargetGroup", local.tg],
        ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", local.lb, "TargetGroup", local.tg],
      ]
    },
    {
      title   = "ECS live tasks"
      stat    = "Minimum"
      metrics = [concat(["AWS/ECS", "LiveTaskCount"], local.ecs)]
    },
    {
      title = "ECS CPU and memory (%)"
      stat  = "Average"
      metrics = [
        concat(["AWS/ECS", "CPUUtilization"], local.ecs),
        concat(["AWS/ECS", "MemoryUtilization"], local.ecs),
      ]
    },
    {
      title = "Aurora CPU and ACU (%)"
      stat  = "Average"
      metrics = [
        concat(["AWS/RDS", "CPUUtilization"], local.db),
        concat(["AWS/RDS", "ACUUtilization"], local.db),
      ]
    },
    {
      title = "Aurora connections"
      stat  = "Maximum"
      metrics = [
        concat(["AWS/RDS", "DatabaseConnections"], local.db),
      ]
    },
    {
      title = "Aurora freeable memory (bytes)"
      stat  = "Minimum"
      metrics = [
        concat(["AWS/RDS", "FreeableMemory"], local.db),
      ]
    },
    {
      title = "WAF requests (sum per 5 min)"
      stat  = "Sum"
      metrics = [
        concat(["AWS/WAFV2", "AllowedRequests"], local.waf),
        concat(["AWS/WAFV2", "BlockedRequests"], local.waf),
        concat(["AWS/WAFV2", "CountedRequests"], local.waf),
      ]
    },
    {
      title = "Payment queue depth (main and DLQ)"
      stat  = "Maximum"
      metrics = [
        concat(["AWS/SQS", "ApproximateNumberOfMessagesVisible"], local.queue),
        concat(["AWS/SQS", "ApproximateNumberOfMessagesNotVisible"], local.queue),
        concat(["AWS/SQS", "ApproximateNumberOfMessagesVisible"], local.dlq),
      ]
    },
    {
      title = "Payment queue oldest message (seconds)"
      stat  = "Maximum"
      metrics = [
        concat(["AWS/SQS", "ApproximateAgeOfOldestMessage"], local.queue),
      ]
    },
    # SLO widgets, using the same math as the alarms in slo.tf. The raw
    # counts are hidden and only feed the expressions.
    {
      title   = "Availability SLI (% good requests per 5 min)"
      stat    = "Sum"
      metrics = concat(local.sli_inputs, [[{ expression = "IF(total > 0, 100 * (1 - bad / total), 100)", label = "Availability %", id = "sli" }]])
      annotations = {
        horizontal = [{ label = "SLO ${local.t.slo_availability_percent}%", value = local.t.slo_availability_percent }]
      }
    },
    {
      title   = "Error budget burn rate (per 5 min)"
      stat    = "Sum"
      metrics = concat(local.sli_inputs, [[{ expression = local.sli_burn, label = "Burn rate", id = "burn" }]])
      annotations = {
        horizontal = [
          { label = "Fast burn ${local.fast_burn_rate}x", value = local.fast_burn_rate },
          { label = "Slow burn ${local.slow_burn_rate}x", value = local.slow_burn_rate },
        ]
      }
    },
    {
      title = "App response time p95 (seconds)"
      stat  = "p95"
      metrics = [
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb, "TargetGroup", local.tg],
      ]
      annotations = {
        horizontal = [{ label = "Alarm ${local.t.latency_p95_seconds}s", value = local.t.latency_p95_seconds }]
      }
    },
  ]

  # Inputs for the SLI and burn rate widgets. Same ids as slo.tf.
  sli_inputs = [
    ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb, { id = "requests", visible = false }],
    ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.lb, { id = "elb5xx", visible = false }],
    ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.lb, "TargetGroup", local.tg, { id = "app5xx", visible = false }],
    [{ expression = local.sli_bad, id = "bad", visible = false }],
    [{ expression = local.sli_total, id = "total", visible = false }],
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name_prefix

  # Two widgets per row, each 12 wide and 6 tall.
  dashboard_body = jsonencode({
    widgets = [
      for i, w in local.widgets : {
        type   = "metric"
        x      = (i % 2) * 12
        y      = floor(i / 2) * 6
        width  = 12
        height = 6
        # Annotations only go on widgets that set them, so the older
        # widgets render exactly as before.
        properties = merge({
          title   = w.title
          region  = local.region
          stat    = w.stat
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = w.metrics
        }, { for k, v in { annotations = try(w.annotations, null) } : k => v if v != null })
      }
    ]
  })
}
