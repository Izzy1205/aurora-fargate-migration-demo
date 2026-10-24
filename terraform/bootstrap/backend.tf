# Same bucket as the main stack, different key. Pass at init:
#   terraform init -backend-config=../backend.hcl \
#     -backend-config="key=aurora-fargate-migration-demo/bootstrap.tfstate"
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
