output "alarm_topic_arn" {
  description = "SNS topic every alarm sends to."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "Names of the CloudWatch alarms."
  value       = sort([for a in aws_cloudwatch_metric_alarm.this : a.alarm_name])
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}
