#!/usr/bin/env bash
# Checks which state key the backends get, with no AWS. state_kms_key in
# lib.sh is what bootstrap.sh passes, and root.hcl works it out again for
# terragrunt. With terragrunt installed this also renders a copy of
# root.hcl for each case and checks the two agree.
#
#   bash scripts/tests/state-kms-key.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$here/../lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ALIAS=alias/migdemo-tfstate

fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  fail=1
}

# A copy of root.hcl and environments/, so the state-bucket tfvars written
# here never touch the real one.
tg=0
mkdir -p "$tmp/terraform/state-bucket"
if command -v terragrunt >/dev/null 2>&1; then
  tg=1
  cp "$REPO_ROOT/terraform/root.hcl" "$tmp/terraform/"
  cp -R "$REPO_ROOT/terraform/environments" "$tmp/terraform/"
  rm -rf "$tmp/terraform/environments/testing/network/.terragrunt-cache"
else
  echo "terragrunt not found, checking lib.sh only"
fi
SB_TFVARS="$tmp/terraform/state-bucket/terraform.tfvars"

# What root.hcl gives testing/network. Prints the key, or nothing when
# kms_key_id is left out.
render_key() {
  MIGDEMO_OWNER=ci terragrunt render --format json --non-interactive \
    --working-dir "$tmp/terraform/environments/testing/network" 2>"$tmp/render.err" |
    jq -r '.remote_state.config.kms_key_id // empty'
}

# case <name> <want> <tfvars or "none"> <env: "unset", or the value>
case_() {
  local name="$1" want="$2" tfvars="$3" envv="$4" got
  if [[ "$tfvars" == none ]]; then rm -f "$SB_TFVARS"; else printf '%s\n' "$tfvars" >"$SB_TFVARS"; fi

  if [[ "$envv" == unset ]]; then
    got=$(unset TF_STATE_KMS_KEY && state_kms_key)
  else
    got=$(TF_STATE_KMS_KEY="$envv" state_kms_key)
  fi
  if [[ "$got" == "$want" ]]; then pass "lib.sh: $name"; else bad "lib.sh: $name (got '$got', want '$want')"; fi

  ((tg)) || return 0
  if [[ "$envv" == unset ]]; then
    got=$(unset TF_STATE_KMS_KEY && render_key) || { bad "root.hcl: $name (render failed)"; cat "$tmp/render.err"; return 0; }
  else
    got=$(TF_STATE_KMS_KEY="$envv" render_key) || { bad "root.hcl: $name (render failed)"; cat "$tmp/render.err"; return 0; }
  fi
  if [[ "$got" == "$want" ]]; then pass "root.hcl: $name"; else bad "root.hcl: $name (got '$got', want '$want')"; fi
}

case_ "no tfvars (CI) uses the key" "$ALIAS" none unset
case_ "use_kms = true uses the key" "$ALIAS" 'use_kms = true' unset
case_ "tfvars without use_kms uses the key" "$ALIAS" 'bucket_name = "b"' unset
case_ "use_kms = false leaves the key out" "" 'use_kms     = false # SSE-S3' unset
case_ "empty TF_STATE_KMS_KEY leaves the key out" "" none ""
case_ "empty TF_STATE_KMS_KEY wins over use_kms = true" "" 'use_kms = true' ""
case_ "TF_STATE_KMS_KEY wins over use_kms = false" alias/other 'use_kms = false' alias/other

exit "$fail"
