# Same bucket as the Terragrunt units, its own key. The key here did not
# change in the Terragrunt refactor. Pass at init:
#   terraform init -backend-config=../backend.hcl \
#     -backend-config="key=aurora-fargate-migration-demo/bootstrap.tfstate"
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
