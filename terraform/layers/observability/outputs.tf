output "alarm_topic_arn" {
  description = "SNS topic every alarm sends to."
  value       = module.observability.alarm_topic_arn
}

output "alarm_names" {
  description = "Names of the CloudWatch alarms."
  value       = module.observability.alarm_names
}

output "dashboard_name" {
  description = "CloudWatch dashboard name. Console: CloudWatch > Dashboards."
  value       = module.observability.dashboard_name
}
