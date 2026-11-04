data "aws_organizations_organization" "this" {}

# Everything here is new: one OU under the root, new SCPs, and attachments
# to that OU only. Nothing attaches to the root or to an OU or account that
# already exists, so existing SCPs (and the accounts they cover) don't
# change. An account only gets these SCPs once it's in ou_account_ids and
# scripts/bootstrap.sh org has moved it in.
resource "aws_organizations_organizational_unit" "demo" {
  name      = var.project
  parent_id = data.aws_organizations_organization.this.roots[0].id

  lifecycle {
    precondition {
      condition     = data.aws_organizations_organization.this.master_account_id == var.management_account_id
      error_message = "The signed in organization's management account is not management_account_id."
    }
    precondition {
      condition     = contains([for p in data.aws_organizations_organization.this.roots[0].policy_types : p.type if p.status == "ENABLED"], "SERVICE_CONTROL_POLICY")
      error_message = "SCPs are not enabled on the organization root. Enable the SERVICE_CONTROL_POLICY type first."
    }
    precondition {
      condition     = alltrue([for a in var.ou_account_ids : contains(data.aws_organizations_organization.this.accounts[*].id, a)])
      error_message = "Every ou_account_ids entry must be an account in this organization."
    }
  }
}

resource "aws_organizations_policy" "scp" {
  for_each = local.scps

  name        = "${var.project}-${each.key}"
  description = each.value.description
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.scp_json[each.key]
}

resource "aws_organizations_policy_attachment" "ou" {
  for_each = local.scps

  policy_id = aws_organizations_policy.scp[each.key].id
  target_id = aws_organizations_organizational_unit.demo.id
}
