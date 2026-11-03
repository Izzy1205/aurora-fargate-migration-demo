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

# The key ARN and id are only known after apply. Fill them in at plan so
# the bucket policy that lists them can be checked.
override_resource {
  target          = aws_kms_key.state
  override_during = plan
  values = {
    arn    = "arn:aws:kms:us-east-2:111111111111:key/00000000-1111-2222-3333-444444444444"
    key_id = "00000000-1111-2222-3333-444444444444"
  }
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
        keys(s.Condition) == ["Null", "StringNotEquals"] &&
        s.Condition["StringNotEquals"]["s3:x-amz-server-side-encryption"] == "aws:kms" &&
        s.Condition["Null"]["s3:x-amz-server-side-encryption"] == "false"
      ) if s.Sid == "DenyNonKmsUploads"
    ]) && contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyNonKmsUploads")
    error_message = "DenyNonKmsUploads must deny PutObject unless it asks for aws:kms or sends no header."
  }

  assert {
    condition     = !contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyWrongKmsKey")
    error_message = "DenyWrongKmsKey must stay off by default."
  }
}

run "deny_wrong_kms_key" {
  command = plan

  variables {
    deny_non_kms_uploads = true
    deny_wrong_kms_key   = true
  }

  # Allowed: the key ARN (reencrypt-state.sh), the alias name (root.hcl
  # and bootstrap.sh), the alias ARN and the bare key id. Anything else is
  # denied. No key id header isn't checked, so the bucket default applies.
  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : (
        s.Effect == "Deny" &&
        s.Action == "s3:PutObject" &&
        s.Resource == "arn:aws:s3:::example-tfstate/*" &&
        s.Principal == "*" &&
        keys(s.Condition) == ["Null", "StringNotEquals"] &&
        s.Condition["Null"]["s3:x-amz-server-side-encryption-aws-kms-key-id"] == "false" &&
        toset(s.Condition["StringNotEquals"]["s3:x-amz-server-side-encryption-aws-kms-key-id"]) == toset([
          "arn:aws:kms:us-east-2:111111111111:key/00000000-1111-2222-3333-444444444444",
          "00000000-1111-2222-3333-444444444444",
          "alias/migdemo-tfstate",
          "arn:aws:kms:us-east-2:111111111111:alias/migdemo-tfstate",
        ])
      ) if s.Sid == "DenyWrongKmsKey"
    ]) && contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyWrongKmsKey")
    error_message = "DenyWrongKmsKey must deny PutObject that names any key but this one, and skip requests with no key id."
  }

  # The deny trusts the alias, so CI must not be able to move it.
  assert {
    condition = alltrue([
      for s in jsondecode(data.aws_iam_policy_document.kms[0].json).Statement : (
        s.Effect == "Deny" &&
        length(setsubtract(["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"], flatten([s.Action]))) == 0
      ) if s.Sid == "DenyCiKeyAdmin"
    ]) && contains([for s in jsondecode(data.aws_iam_policy_document.kms[0].json).Statement : s.Sid], "DenyCiKeyAdmin")
    error_message = "DenyCiKeyAdmin must deny CI the alias actions."
  }
}

run "deny_wrong_kms_key_alone" {
  command = plan

  variables {
    deny_wrong_kms_key = true
  }

  assert {
    condition = (
      contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyWrongKmsKey") &&
      !contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyNonKmsUploads")
    )
    error_message = "deny_wrong_kms_key works without deny_non_kms_uploads."
  }
}

run "sse_s3_bucket" {
  command = plan

  variables {
    use_kms              = false
    deny_non_kms_uploads = true
    deny_wrong_kms_key   = true
  }

  assert {
    condition     = !contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyNonKmsUploads")
    error_message = "With use_kms = false there's no key, so no KMS-only deny."
  }

  assert {
    condition     = !contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyWrongKmsKey")
    error_message = "With use_kms = false there's no key to match."
  }
}
