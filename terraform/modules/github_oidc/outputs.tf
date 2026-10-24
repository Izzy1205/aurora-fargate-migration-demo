output "plan_role_arn" {
  description = "Set as GitHub variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "terraform_role_arn" {
  description = "Set as GitHub variable AWS_TERRAFORM_ROLE_ARN."
  value       = aws_iam_role.apply.arn
}

output "deploy_role_arn" {
  description = "Set as GitHub variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}
