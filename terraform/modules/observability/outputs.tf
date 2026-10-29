output "alarm_topic_arn" {
  description = "SNS topic every alarm sends to."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "Names of the CloudWatch alarms, metric and composite."
  value = sort(concat(
    [for a in aws_cloudwatch_metric_alarm.this : a.alarm_name],
    [aws_cloudwatch_metric_alarm.latency_p95.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.burn : a.alarm_name],
    [aws_cloudwatch_composite_alarm.fast_burn.alarm_name, aws_cloudwatch_composite_alarm.slow_burn.alarm_name],
  ))
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}
