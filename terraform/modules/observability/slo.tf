# SLO alarms for the web front door: one latency alarm and four burn rate
# alarms, joined into two composite alarms that actually notify.
#
# The words, in short:
#   - SLI (what we measure): the share of requests through the ALB that did
#     not come back as a 5xx. ALB 5xx (no healthy target, timeout) and app
#     5xx both count as bad.
#   - SLO (the target): thresholds.slo_availability_percent of requests are
#     good over a rolling 30 days. 99.9 by default.
#   - Error budget: what the SLO lets us fail. At 99.9 that's 0.1% of
#     requests, or about 43 minutes of full outage in 30 days.
#   - Burn rate: how fast we're spending that budget. It's the error rate we
#     see divided by the error rate the SLO allows. A burn rate of 1 uses up
#     the budget in exactly 30 days. 14.4 uses 2% of it in one hour.
#
# Why burn rate instead of "more than N errors": a fixed count means very
# different things at 10 requests and at 10,000. Burn rate scales with
# traffic and ties the alert to the promise we made, not to a number we
# guessed.
#
# Why two windows per alert (from the Google SRE workbook, "Alerting on
# SLOs"): the long window proves the problem is big enough to matter. The
# short window, 1/12 of the long one, proves it's still happening. Both have
# to be over the line, so the alert fires fast and also clears within
# minutes of the fix, not an hour later.
#   - Fast burn: 14.4x over 1 hour AND over 5 minutes. 2% of the month's
#     budget gone in an hour. This is the page.
#   - Slow burn: 6x over 6 hours AND over 30 minutes. 5% gone in 6 hours.
#     The workbook pages on this one too; here it's the ticket, something to
#     fix in working hours before it becomes a page.
# There's one email topic in this demo, so page and ticket are labels in the
# alarm name and description. A real setup would send the page to the
# on-call tool and the ticket to the team queue.
#
# Low traffic caveat: with a handful of requests, one 5xx is a big share,
# so a single bad request can trip both windows. That's the honest math at
# demo traffic. Busier envs don't have the problem.
#
# Limits checked against the PutMetricAlarm API docs: period times
# evaluation periods can be up to 1 day when the period is under an hour,
# and up to 7 days at an hour or more. Every window here is one period of
# 5 minutes to 6 hours, so all are inside that. Alarms are evaluated every
# minute on a sliding window, so a 6 hour window means "the last 6 hours",
# rolled forward each minute.

locals {
  # Error budget as a fraction, e.g. 99.9 -> 0.001. format() keeps the
  # number short and exact in the expression text.
  error_budget = format("%.6g", (100 - local.t.slo_availability_percent) / 100)

  # The workbook's numbers for a 30 day SLO window. Change them together
  # with the window, not on their own.
  fast_burn_rate = 14.4
  slow_burn_rate = 6

  burn_windows = {
    fast-1h  = { seconds = 3600, rate = local.fast_burn_rate, label = "1 hour" }
    fast-5m  = { seconds = 300, rate = local.fast_burn_rate, label = "5 minutes" }
    slow-6h  = { seconds = 21600, rate = local.slow_burn_rate, label = "6 hours" }
    slow-30m = { seconds = 1800, rate = local.slow_burn_rate, label = "30 minutes" }
  }

  # The SLI math, shared by the alarms and the dashboard.
  #   bad   = ALB 5xx + app 5xx. Both only report when above 0, so FILL
  #           turns "no data" into 0.
  #   total = the larger of RequestCount and bad. RequestCount skips
  #           requests the ALB rejects before it picks a target, like the
  #           503s when no task is healthy. Without the MAX, a full outage
  #           would have 0 requests, divide by zero, and look like no data.
  #   burn  = (bad / total) / budget, or 0 when there's no traffic, so a
  #           quiet env never alarms and never divides by zero.
  sli_bad   = "FILL(elb5xx, 0) + FILL(app5xx, 0)"
  sli_total = "MAX([FILL(requests, 0), bad])"
  sli_burn  = "IF(total > 0, (bad / total) / ${local.error_budget}, 0)"
}

# Slow responses. The SLI above only counts errors, so this covers the other
# way users get hurt. p95 means 1 in 20 requests is slower than this. Three
# 5 minute periods in a row, so one slow request at demo traffic doesn't
# alert by itself. No data means no traffic, which is fine.
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

# One burn rate alarm per window. These have no actions on purpose: on
# their own they'd be noisy. The composite alarms below notify when a long
# and a short window agree.
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

# Page: fast burn, both windows over 14.4x.
resource "aws_cloudwatch_composite_alarm" "fast_burn" {
  alarm_name        = "${var.name_prefix}-slo-fast-burn"
  alarm_description = "PAGE. Spending the error budget at 14.4x or more over both the last hour and the last 5 minutes. At this rate the whole 30 day budget is gone in about 2 days. Check recent deploys and roll back first."

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.burn["fast-1h"].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.burn["fast-5m"].alarm_name}\")"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  depends_on = [aws_sns_topic_policy.alarms]
}

# Ticket: slow burn, both windows over 6x.
resource "aws_cloudwatch_composite_alarm" "slow_burn" {
  alarm_name        = "${var.name_prefix}-slo-slow-burn"
  alarm_description = "TICKET. Spending the error budget at 6x or more over both the last 6 hours and the last 30 minutes. At this rate the 30 day budget is gone in about 5 days. Fix in working hours."

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.burn["slow-6h"].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.burn["slow-30m"].alarm_name}\")"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  depends_on = [aws_sns_topic_policy.alarms]
}
