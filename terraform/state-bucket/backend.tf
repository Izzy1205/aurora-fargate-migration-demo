# This root manages the bucket its own state lives in. The first apply runs
# with a local backend (scripts/bootstrap.sh writes a gitignored
# backend_override.tf), then the state moves into the bucket with
# terraform init -migrate-state. Later runs use S3 directly.
#
# Partial config, passed at init by scripts/bootstrap.sh state-bucket:
#   -backend-config="bucket=<state bucket>"
#   -backend-config="key=aurora-fargate-migration-demo/bootstrap-state-bucket.tfstate"
#   -backend-config="region=<bucket region>"
#   -backend-config="kms_key_id=alias/migdemo-tfstate" (skipped when use_kms = false)
# The key starts with bootstrap so the CI roles' deny on bootstrap* state
# keys covers it.
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
