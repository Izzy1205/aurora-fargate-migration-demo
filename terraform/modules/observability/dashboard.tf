# One dashboard with the same metrics the alarms watch. The first three
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
        properties = {
          title   = w.title
          region  = local.region
          stat    = w.stat
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = w.metrics
        }
      }
    ]
  })
}
