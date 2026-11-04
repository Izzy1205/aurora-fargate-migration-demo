#!/usr/bin/env bash
# Optional, one time. Copies state objects in the state bucket onto
# themselves with the state KMS key, so state written before the backends
# set kms_key_id isn't left on SSE-S3. Each copy is a new version. The old
# SSE-S3 versions stay until the bucket's lifecycle rule expires them.
# Run from a machine with admin creds, never from CI. See --help.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/reencrypt-state.sh [--dry-run] [--prefix <prefix>] [--env <env>]

Lists every object in the state bucket not encrypted with the state key,
then, after you type reencrypt, copies each one in place with SSE-KMS.

Options:
  --dry-run          List what would be copied. Changes nothing.
  --prefix <prefix>  Only objects under this prefix. Default: whole bucket.
  --env <env>        Whose account and profile to use, from
                     terraform/accounts.hcl. Default: testing. An env with
                     its own account reads terraform/state-bucket/<env>.tfvars.
  -h, --help         Show this help.

Values:
  bucket  TF_STATE_BUCKET, then bucket_name in terraform/state-bucket/terraform.tfvars
  region  TF_STATE_REGION, then aws_region there, then us-east-2
  key     TF_STATE_KMS_KEY, then alias/<project>-tfstate

Run it when no pipeline or local terraform is running. A state with a
.tflock next to it is skipped, since something holds its lock.
USAGE
}

DRY_RUN=0
PREFIX=""
ENV_NAME=testing
while (($#)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --dry-run) DRY_RUN=1 ;;
    --prefix)
      [[ $# -ge 2 ]] || die "--prefix needs a value."
      PREFIX="$2"
      shift
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env needs a value."
      [[ "$2" == testing || "$2" == stage || "$2" == production ]] || die "--env takes testing, stage or production."
      ENV_NAME="$2"
      shift
      ;;
    *)
      usage >&2
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

# needs_copy <sse> <key id> <want key arn>. 0 if the object isn't on the key.
needs_copy() {
  [[ "$1" != aws:kms || "$2" != "$3" ]]
}

main() {
  local bucket region kms key_arn keys k meta sse kid
  local todo=() locks=() ok=0 skipped=0

  # An env in its own account has its own bucket and tfvars.
  if [[ "$ENV_NAME" != testing && "$(env_account "$ENV_NAME")" != "$(env_account testing)" ]]; then
    SB_TFVARS="$REPO_ROOT/terraform/state-bucket/$ENV_NAME.tfvars"
  fi
  bucket="${TF_STATE_BUCKET:-}"
  [[ -n "$bucket" || ! -f "$SB_TFVARS" ]] || bucket=$(hcl_value bucket_name "$SB_TFVARS")
  [[ -n "$bucket" ]] || die "Set TF_STATE_BUCKET, or bucket_name in terraform/state-bucket/terraform.tfvars."
  region="${TF_STATE_REGION:-$(resolve_region "$SB_TFVARS")}"
  kms=$(state_kms_key)
  [[ -n "$kms" ]] || die "No state key: use_kms = false in terraform/state-bucket, or TF_STATE_KMS_KEY is empty."

  log_init reencrypt-state
  ((DRY_RUN)) && info "Dry run"
  require_tools aws jq
  use_env "$ENV_NAME"

  # tr -d '\r': aws and jq on Windows can end lines with CRLF.
  key_arn=$(aws kms describe-key --key-id "$kms" --region "$region" --query KeyMetadata.Arn --output text | tr -d '\r') ||
    die "Could not read $kms in $region."
  [[ "$key_arn" == arn:* ]] || die "describe-key returned \"$key_arn\" for $kms, not a key ARN."
  info "Bucket s3://$bucket ($region), key $key_arn"

  keys=$(aws s3api list-objects-v2 --bucket "$bucket" --region "$region" ${PREFIX:+--prefix "$PREFIX"} --output json |
    jq -r '.Contents[]?.Key' | tr -d '\r')
  [[ -n "$keys" ]] || {
    info "No objects under s3://$bucket/$PREFIX"
    return 0
  }

  while IFS= read -r k; do
    [[ "$k" == *.tflock ]] && locks+=("${k%.tflock}")
  done <<<"$keys"

  while IFS= read -r k; do
    [[ "$k" == *.tflock ]] && continue
    if [[ " ${locks[*]-} " == *" $k "* ]]; then
      warn "Skipping $k: it has a .tflock, something holds its lock."
      skipped=$((skipped + 1))
      continue
    fi
    meta=$(aws s3api head-object --bucket "$bucket" --key "$k" --region "$region" --output json |
      jq -r '[.ServerSideEncryption // "none", .SSEKMSKeyId // "-"] | @tsv' | tr -d '\r') ||
      die "Could not read $k."
    IFS=$'\t' read -r sse kid <<<"$meta"
    if needs_copy "$sse" "$kid" "$key_arn"; then
      printf '  %-8s %s\n' "$sse" "$k"
      todo+=("$k")
    else
      ok=$((ok + 1))
    fi
  done <<<"$keys"

  info "${#todo[@]} to copy, $ok already on the key, $skipped skipped"
  ((${#todo[@]})) || return 0
  if ((DRY_RUN)); then
    info "Dry run: nothing copied."
    return 0
  fi

  confirm reencrypt "copy the ${#todo[@]} objects above in place with SSE-KMS"
  for k in "${todo[@]}"; do
    # Same SHA256 checksum the backend writes with.
    aws s3api copy-object --bucket "$bucket" --key "$k" --copy-source "$bucket/$k" \
      --region "$region" --metadata-directive COPY --checksum-algorithm SHA256 \
      --server-side-encryption aws:kms --ssekms-key-id "$key_arn" >/dev/null ||
      die "Copy failed for $k. Objects before it are done. Run again to finish."
    info "copied $k"
  done
  info "Done. Run with --dry-run again to check."
}

# Tests source this file for needs_copy without running main.
[[ "${REENCRYPT_SOURCE_ONLY:-0}" == 1 ]] || main
