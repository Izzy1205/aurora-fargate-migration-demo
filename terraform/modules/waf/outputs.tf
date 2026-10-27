output "web_acl_name" {
  description = "Web ACL name, the WebACL dimension in the AWS/WAFV2 metrics."
  value       = aws_wafv2_web_acl.this.name
}

output "web_acl_arn" {
  description = "Web ACL ARN."
  value       = aws_wafv2_web_acl.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group with the WAF logs."
  value       = aws_cloudwatch_log_group.waf.name
}
