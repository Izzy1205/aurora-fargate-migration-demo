# Local state, on purpose. This root runs from the management account by
# hand, and the only state bucket lives in the testing member account. Every
# CI role in that account has ReadOnlyAccess (s3:Get*), and the deny on
# other state only covers <key root>/bootstrap*, so an org/ key there would
# be readable from CI. Local state is out of reach of every CI role and
# needs nothing from the member account.
#
# terraform.tfstate here is gitignored (*.tfstate). It holds policy text
# and IDs, no secrets. Keep a copy somewhere safe. If it's lost, import the
# OU, the policies and the attachments again (see terraform/org/README.md).
# When the management account gets its own state bucket, move it there with
# terraform init -migrate-state.
terraform {
  backend "local" {}
}
