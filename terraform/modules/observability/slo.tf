# Availability SLO with fast and slow burn alerts (14.4x and 6x, from the SRE workbook).
# Fast burn is the page, slow burn is the ticket. At demo traffic one bad request can trip it.

locals {
  # format() keeps the number short in the expression text.
  error_budget = format("%.6g", (100 - local.t.slo_availability_percent) / 100)

  # Tied to the 30 day window. Change them together.
  fast_burn_rate = 14.4
  slow_burn_rate = 6

  burn_windows = {
    fast-1h  = { seconds = 3600, rate = local.fast_burn_rate, label = "1 hour" }
    fast-5m  = { seconds = 300, rate = local.fast_burn_rate, label = "5 minutes" }
    slow-6h  = { seconds = 21600, rate = local.slow_burn_rate, label = "6 hours" }
    slow-30m = { seconds = 1800, rate = local.slow_burn_rate, label = "30 minutes" }
  }

  # MAX() so a full outage, where the ALB rejects before RequestCount, reads as 100% errors.
  # FILL turns "no data" into 0. No traffic means burn 0.
  sli_bad   = "FILL(elb5xx, 0) + FILL(app5xx, 0)"
  sli_total = "MAX([FILL(requests, 0), bad])"
  sli_burn  = "IF(total > 0, (bad / total) / ${local.error_budget}, 0)"
}

# p95 over three 5 min periods so one slow request doesn't alert.
resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name        = "${var.name_prefix}-latency-p95"
  alarm_description = "p95 app response time through the ALB is over ${local.t.latency_p95_seconds}s for 15 minutes. See slo.tf in the observability module."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  dimensions          = local.tg_dims
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.t.latency_p95_seconds
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  depends_on = [aws_sns_topic_policy.alarms]
}

# No actions on purpose. The composites below notify.
resource "aws_cloudwatch_metric_alarm" "burn" {
  for_each = local.burn_windows

  alarm_name        = "${var.name_prefix}-slo-burn-${each.key}"
  alarm_description = "Error budget burn rate over the last ${each.value.label} is at least ${each.value.rate}x (SLO ${local.t.slo_availability_percent}% over 30 days). No actions; feeds the slo-fast-burn and slo-slow-burn composite alarms."

  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.rate
  treat_missing_data  = "notBreaching"

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = local.lb_dims
      stat        = "Sum"
      period      = each.value.seconds
    }
  }

  metric_query {
    id = "elb5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = local.lb_dims
      stat        = "Sum"
      period      = each.value.seconds
    }
  }

  metric_query {
    id = "app5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.tg_dims
      stat        = "Sum"
      period      = each.value.seconds
    }
  }

  metric_query {
    id         = "bad"
    expression = local.sli_bad
  }

  metric_query {
    id         = "total"
    expression = local.sli_total
  }

  metric_query {
    id          = "burn"
    expression  = local.sli_burn
    label       = "Burn rate (${each.value.label})"
    return_data = true
  }
}

# Page: both windows over 14.4x.
resource "aws_cloudwatch_composite_alarm" "fast_burn" {
  alarm_name        = "${var.name_prefix}-slo-fast-burn"
  alarm_description = "PAGE. Spending the error budget at 14.4x or more over both the last hour and the last 5 minutes. At this rate the whole 30 day budget is gone in about 2 days. Check recent deploys and roll back first."

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.burn["fast-1h"].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.burn["fast-5m"].alarm_name}\")"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  depends_on = [aws_sns_topic_policy.alarms]
}

# Ticket: both windows over 6x.
resource "aws_cloudwatch_composite_alarm" "slow_burn" {
  alarm_name        = "${var.name_prefix}-slo-slow-burn"
  alarm_description = "TICKET. Spending the error budget at 6x or more over both the last 6 hours and the last 30 minutes. At this rate the 30 day budget is gone in about 5 days. Fix in working hours."

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.burn["slow-6h"].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.burn["slow-30m"].alarm_name}\")"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  depends_on = [aws_sns_topic_policy.alarms]
}
