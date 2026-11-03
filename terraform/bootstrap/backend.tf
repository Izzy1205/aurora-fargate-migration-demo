# Same bucket as the Terragrunt units, its own key per environment. Testing
# keeps the key it always had. Pass at init (-reconfigure when switching):
#   testing:    key=aurora-fargate-migration-demo/bootstrap.tfstate
#   stage:      key=aurora-fargate-migration-demo/bootstrap-stage.tfstate
#   production: key=aurora-fargate-migration-demo/bootstrap-production.tfstate
#   terraform init -reconfigure -backend-config=../backend.hcl \
#     -backend-config="key=aurora-fargate-migration-demo/bootstrap-stage.tfstate"
# scripts/bootstrap.sh also passes kms_key_id=alias/migdemo-tfstate (the
# state bucket's key) so state is SSE-KMS, not AES256.
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
