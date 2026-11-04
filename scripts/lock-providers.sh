#!/usr/bin/env bash
# Refreshes the provider hashes in every committed .terraform.lock.hcl for
# the platforms we run on, so init on Windows, a Mac or CI doesn't rewrite
# them. Keeps the versions already locked. Talks to the Terraform registry
# only, no AWS.
#
#   scripts/lock-providers.sh
#
# The units under terraform/environments are Terragrunt units. Running
# providers lock through terragrunt would init the S3 backend and read
# dependency outputs, which needs AWS. The lock only depends on
# required_providers, so each unit is locked from a temp copy of its layer's
# versions.tf plus its current lock file, then copied back.
# https://developer.hashicorp.com/terraform/cli/commands/providers/lock
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

PLATFORMS=(linux_amd64 windows_amd64 darwin_arm64 darwin_amd64)
TF="$REPO_ROOT/terraform"

args=()
for p in "${PLATFORMS[@]}"; do args+=(-platform="$p"); done

require_tools terraform

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# One download per provider and platform, not one per unit.
export TF_PLUGIN_CACHE_DIR="$tmp/cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

for d in bootstrap state-bucket org; do
  info "$d"
  (cd "$TF/$d" && terraform providers lock -enable-plugin-cache "${args[@]}")
done

for unit in "$TF"/environments/*/*/; do
  unit="${unit%/}"
  [[ -f "$unit/terragrunt.hcl" ]] || continue
  layer=$(basename "$unit")
  [[ -f "$TF/layers/$layer/versions.tf" ]] || die "No terraform/layers/$layer/versions.tf for ${unit#"$REPO_ROOT"/}"
  info "${unit#"$REPO_ROOT"/}"
  work="$tmp/$(basename "$(dirname "$unit")")-$layer"
  mkdir -p "$work"
  cp "$TF/layers/$layer/versions.tf" "$work/"
  [[ -f "$unit/.terraform.lock.hcl" ]] && cp "$unit/.terraform.lock.hcl" "$work/"
  (cd "$work" && terraform providers lock -enable-plugin-cache "${args[@]}")
  cp "$work/.terraform.lock.hcl" "$unit/.terraform.lock.hcl"
done

info "Done. Check git diff: only hashes should change, not versions."
