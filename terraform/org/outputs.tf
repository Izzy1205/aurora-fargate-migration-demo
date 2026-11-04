output "ou_id" {
  description = "The demo OU."
  value       = aws_organizations_organizational_unit.demo.id
}

output "ou_account_ids" {
  description = "Accounts scripts/bootstrap.sh org moves into the OU."
  value       = var.ou_account_ids
}

output "policy_ids" {
  description = "SCP IDs by name."
  value       = { for k, p in aws_organizations_policy.scp : k => p.id }
}

output "policy_sizes" {
  description = "Characters in each SCP. The limit is 5,120."
  value       = { for k, j in local.scp_json : k => length(j) }
}

output "allowed_regions" {
  description = "Regions the region lock allows."
  value       = local.regions
}
