# Partial backend config. Bucket, key and region come from backend.hcl
# (copy backend.hcl.example, never commit the real one) or from
# -backend-config flags in CI.
#
# use_lockfile = true uses S3 native locking (a .tflock object next to the
# state), so there is no DynamoDB lock table to create or pay for.
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
