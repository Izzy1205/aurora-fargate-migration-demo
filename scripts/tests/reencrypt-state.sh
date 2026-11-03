#!/usr/bin/env bash
# Checks what reencrypt-state.sh would copy, with a fake aws and no AWS.
#
#   bash scripts/tests/reencrypt-state.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../reencrypt-state.sh
REENCRYPT_SOURCE_ONLY=1 . "$here/../reencrypt-state.sh"
set +e

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
KEY=arn:aws:kms:us-east-2:111111111111:key/test
export TF_STATE_BUCKET=example-tfstate TF_STATE_REGION=us-east-2 TF_STATE_KMS_KEY=alias/migdemo-tfstate

# No logging, tools, sign in or account checks here.
log_init() { :; }
require_tools() { :; }
ensure_session() { :; }
check_account() { :; }

# Objects and their encryption. A copy is logged to $tmp/copies.
aws() {
  case "$1 $2" in
    "kms describe-key") printf '%s\r\n' "$KEY" ;;
    "s3api list-objects-v2")
      printf '{"Contents":[{"Key":"a/testing/network/terraform.tfstate"},{"Key":"a/testing/data/terraform.tfstate"},{"Key":"a/testing/app/terraform.tfstate"},{"Key":"a/testing/app/terraform.tfstate.tflock"},{"Key":"a/bootstrap.tfstate"},{"Key":"plans/1/testing/network.tfplan"}]}'
      ;;
    "s3api head-object")
      local k
      k=$(printf '%s\n' "$@" | sed -n '/^--key$/{n;p;}')
      case "$k" in
        a/testing/network/terraform.tfstate) echo '{"ServerSideEncryption":"AES256"}' ;;
        a/bootstrap.tfstate) echo "{\"ServerSideEncryption\":\"aws:kms\",\"SSEKMSKeyId\":\"arn:aws:kms:us-east-2:111111111111:key/other\"}" ;;
        *) echo "{\"ServerSideEncryption\":\"aws:kms\",\"SSEKMSKeyId\":\"$KEY\"}" ;;
      esac
      ;;
    "s3api copy-object") printf '%s\n' "$*" >>"$tmp/copies" ;;
    *)
      echo "unexpected aws $*" >&2
      return 1
      ;;
  esac
}

fails=0
# check <name>, right after the test. Reads the test's exit status.
check() {
  local status=$?
  if ((status == 0)); then echo "ok    $1"; else
    echo "FAIL  $1"
    fails=1
  fi
}

needs_copy AES256 - "$KEY"
check "needs_copy: SSE-S3"
needs_copy aws:kms arn:other "$KEY"
check "needs_copy: other key"
[[ $(needs_copy aws:kms "$KEY" "$KEY" || echo no) == no ]]
check "needs_copy: right key"

DRY_RUN=1
out=$(main 2>&1)
[[ "$out" == *"AES256   a/testing/network/terraform.tfstate"* ]]
check "dry run lists the SSE-S3 state"
[[ "$out" == *"aws:kms  a/bootstrap.tfstate"* ]]
check "dry run lists a state on another key"
[[ "$out" == *"Skipping a/testing/app/terraform.tfstate"* ]]
check "dry run skips a locked state"
[[ "$out" == *"2 to copy, 2 already on the key, 1 skipped"* ]]
check "dry run counts"
[[ ! -e "$tmp/copies" ]]
check "dry run copies nothing"

DRY_RUN=0
out=$(echo no | main 2>&1)
[[ ! -e "$tmp/copies" && "$out" == *"Stopped"* ]]
check "anything but reencrypt stops"

out=$(echo reencrypt | main 2>&1)
[[ "$out" == *"Done."* ]]
check "real run finishes"
[[ $(wc -l <"$tmp/copies") -eq 2 ]]
check "copies two"
[[ $(grep -cv -- "--ssekms-key-id $KEY" "$tmp/copies") == 0 ]]
check "copies with the key ARN"
[[ $(grep -cE "tflock|testing/app/" "$tmp/copies") == 0 ]]
check "never copies a lock or a locked state"

exit "$fails"
