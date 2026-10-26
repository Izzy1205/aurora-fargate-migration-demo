output "plan_role_arn" {
  description = "Set as GitHub variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "terraform_role_arn" {
  description = "Set as GitHub variable AWS_TERRAFORM_ROLE_ARN."
  value       = aws_iam_role.apply.arn
}

output "workload_boundary_arn" {
  description = "Permissions boundary the main stack puts on every role it creates."
  value       = aws_iam_policy.workload_boundary.arn
}

output "deploy_role_arn" {
  description = "Set as GitHub variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}
