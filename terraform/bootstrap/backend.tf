# Same bucket as the Terragrunt units, its own key per environment. Testing
# keeps the key it always had. Pass at init (-reconfigure when switching):
#   testing:    key=aurora-fargate-migration-demo/bootstrap.tfstate
#   stage:      key=aurora-fargate-migration-demo/bootstrap-stage.tfstate
#   production: key=aurora-fargate-migration-demo/bootstrap-production.tfstate
#   terraform init -reconfigure -backend-config=../backend.hcl \
#     -backend-config="key=aurora-fargate-migration-demo/bootstrap-stage.tfstate"
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
