# Adopts a bucket made by hand. scripts/bootstrap.sh state-bucket sets
# import_existing_bucket=true when the bucket exists and this root has no
# state yet. The bucket policy and lifecycle rules are not imported: a hand
# made bucket usually has neither, and creating them replaces whatever is
# there. The plan shows the result before anything is applied.

locals {
  import_ids = var.import_existing_bucket ? toset([var.bucket_name]) : toset([])
}

import {
  for_each = local.import_ids
  to       = aws_s3_bucket.state
  id       = each.value
}

import {
  for_each = local.import_ids
  to       = aws_s3_bucket_versioning.state
  id       = each.value
}

import {
  for_each = local.import_ids
  to       = aws_s3_bucket_server_side_encryption_configuration.state
  id       = each.value
}

import {
  for_each = local.import_ids
  to       = aws_s3_bucket_public_access_block.state
  id       = each.value
}

import {
  for_each = local.import_ids
  to       = aws_s3_bucket_ownership_controls.state
  id       = each.value
}
