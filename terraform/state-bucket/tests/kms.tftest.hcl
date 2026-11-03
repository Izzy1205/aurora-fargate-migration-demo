# Plan-only checks on the state key and bucket policies. No AWS calls: the
# provider uses placeholder keys with every remote check skipped.
# Run: terraform init -backend=false && terraform test

provider "aws" {
  region                      = "us-east-2"
  access_key                  = "placeholder"
  secret_key                  = "placeholder"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "111111111111" }
}

override_data {
  target = data.aws_partition.current
  values = { partition = "aws" }
}

variables {
  owner       = "someone"
  bucket_name = "example-tfstate"
  aws_region  = "us-east-2"
}

run "key_policy" {
  command = plan

  # SSE-KMS needs GenerateDataKey to write and Decrypt to read, nothing
  # more, and only through S3 for this bucket.
  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.kms[0].json).Statement : (
        toset(flatten([s.Action])) == toset(["kms:Decrypt", "kms:GenerateDataKey"]) &&
        s.Condition["StringEquals"]["kms:ViaService"] == "s3.us-east-2.amazonaws.com" &&
        s.Condition["StringEquals"]["kms:CallerAccount"] == "111111111111" &&
        s.Condition["ArnLike"]["aws:PrincipalArn"] == "arn:aws:iam::111111111111:role/migdemo-*-github-*" &&
        toset(s.Condition["StringLike"]["kms:EncryptionContext:aws:s3:arn"]) == toset(["arn:aws:s3:::example-tfstate", "arn:aws:s3:::example-tfstate/*"])
      ) if s.Sid == "CiRolesUseThroughS3"
    ]) && contains([for s in jsondecode(data.aws_iam_policy_document.kms[0].json).Statement : s.Sid], "CiRolesUseThroughS3")
    error_message = "CiRolesUseThroughS3 must grant only Decrypt and GenerateDataKey, through S3, for this bucket."
  }

  assert {
    condition     = aws_kms_alias.state[0].name == "alias/migdemo-tfstate"
    error_message = "The alias must match the kms_key_id in root.hcl and scripts/lib.sh."
  }

  assert {
    condition     = !contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyNonKmsUploads")
    error_message = "DenyNonKmsUploads must stay off by default."
  }
}

run "deny_non_kms_uploads" {
  command = plan

  variables {
    deny_non_kms_uploads = true
  }

  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : (
        s.Effect == "Deny" &&
        s.Action == "s3:PutObject" &&
        s.Condition["StringNotEqualsIfExists"]["s3:x-amz-server-side-encryption"] == "aws:kms"
      ) if s.Sid == "DenyNonKmsUploads"
    ]) && contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyNonKmsUploads")
    error_message = "DenyNonKmsUploads must deny PutObject unless it asks for aws:kms or sends no header."
  }
}

run "sse_s3_bucket" {
  command = plan

  variables {
    use_kms              = false
    deny_non_kms_uploads = true
  }

  assert {
    condition     = !contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyNonKmsUploads")
    error_message = "With use_kms = false there's no key, so no KMS-only deny."
  }
}
