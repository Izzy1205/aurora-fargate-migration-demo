#!/usr/bin/env bash
# Shared helpers for the operator scripts. Source it, don't run it.
#   . "$(dirname "$0")/lib.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "lib.sh is meant to be sourced." >&2
  exit 1
fi

# Repo root, from this file's location.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# Minimum versions. aws login needs 2.32.0. gh variable get with -R needs 2.55.0.
min_version() {
  case "$1" in
    aws) echo 2.32.0 ;;
    terraform) echo 1.17.0 ;;
    terragrunt) echo 1.2.1 ;;
    gh) echo 2.55.0 ;;
    jq) echo 1.6 ;;
    openssl) echo 1.1.1 ;;
    *) echo "" ;;
  esac
}

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# First quoted value of `name = "value"` in an HCL or tfvars file.
hcl_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2" | head -n 1
}

# First unquoted value (bool or number) of `name = value`.
hcl_raw() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([A-Za-z0-9_.-]*\).*/\1/p" "$2" | head -n 1
}

# Log everything from here on to logs/<timestamp>-<cmd>.log and the screen.
log_init() {
  local cmd="${1:?log_init needs a name}"
  mkdir -p "$REPO_ROOT/logs"
  LOG_FILE="$REPO_ROOT/logs/$(date +%Y%m%d-%H%M%S)-${cmd}.log"
  export LOG_FILE
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Logging to ${LOG_FILE#"$REPO_ROOT"/}"
}

# 0 if $1 >= $2, comparing dotted numbers.
version_ge() {
  local IFS=.
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  local i x y
  for ((i = 0; i < ${#b[@]} || i < ${#a[@]}; i++)); do
    x=$((10#${a[i]:-0}))
    y=$((10#${b[i]:-0}))
    ((x > y)) && return 0
    ((x < y)) && return 1
  done
  return 0
}

# Installed version of a tool, as plain x.y.z.
tool_version() {
  local out
  case "$1" in
    aws) out=$(aws --version 2>&1) ;;
    terraform) out=$(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null) ;;
    terragrunt) out=$(terragrunt --version 2>&1) ;;
    gh) out=$(gh --version 2>&1 | head -n 1) ;;
    jq) out=$(jq --version 2>&1) ;;
    openssl) out=$(openssl version 2>&1) ;;
    *) return 1 ;;
  esac
  grep -oE '[0-9]+(\.[0-9]+)+' <<<"$out" | head -n 1
}

# require_tools aws terraform jq ...
require_tools() {
  local t v min missing=0
  for t in "$@"; do
    min=$(min_version "$t")
    if ! command -v "$t" >/dev/null 2>&1; then
      warn "$t not found on PATH (need ${min:-any version})"
      missing=1
      continue
    fi
    [[ -n "$min" ]] || continue
    v=$(tool_version "$t" || true)
    if [[ -z "$v" ]]; then
      warn "could not read the $t version"
      missing=1
    elif ! version_ge "$v" "$min"; then
      warn "$t $v is older than $min"
      missing=1
    fi
  done
  ((missing == 0)) || die "Install or upgrade the tools above, then run again."
}

# Project name from terraform/root.hcl.
resolve_project() {
  local p
  p=$(hcl_value project "$REPO_ROOT/terraform/root.hcl")
  [[ -n "$p" ]] || die "Could not read project from terraform/root.hcl"
  printf '%s\n' "$p"
}

# Region: AWS_REGION, then aws_region in the given tfvars, then us-east-2.
resolve_region() {
  local r="${AWS_REGION:-}"
  if [[ -z "$r" && -n "${1:-}" && -f "$1" ]]; then
    r=$(hcl_value aws_region "$1")
  fi
  printf '%s\n' "${r:-us-east-2}"
}

# Account the credentials are for.
current_account() {
  aws sts get-caller-identity --query Account --output text
}

# Account the scripts may run against: MIGDEMO_ACCOUNT_ID, then
# expected_account_id in terraform/state-bucket/terraform.tfvars.
expected_account() {
  local acct="${MIGDEMO_ACCOUNT_ID:-}"
  local f="$REPO_ROOT/terraform/state-bucket/terraform.tfvars"
  if [[ -z "$acct" && -f "$f" ]]; then
    acct=$(hcl_value expected_account_id "$f")
  fi
  printf '%s\n' "$acct"
}

# Stop unless the credentials are for the expected account.
check_account() {
  local want have
  want=$(expected_account)
  [[ "$want" =~ ^[0-9]{12}$ ]] ||
    die "Set MIGDEMO_ACCOUNT_ID, or expected_account_id in terraform/state-bucket/terraform.tfvars."
  have=$(current_account) || die "Could not read the account from aws sts get-caller-identity."
  [[ "$have" == "$want" ]] || die "Signed in to account $have, expected $want. Sign in to the right account."
  info "Account $have matches."
}

# Sign in if there's no working session.
ensure_session() {
  if aws sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi
  session_refresh
}

# Sign in again. Use before a long run so the session doesn't expire midway.
session_refresh() {
  info "Signing in with aws login"
  aws login || die "aws login failed."
  aws sts get-caller-identity >/dev/null 2>&1 || die "Still no AWS session after aws login."
}

# confirm <word> <what>. Stops unless the operator types the word exactly.
confirm() {
  local want="$1" what="${2:-continue}" got=""
  printf '\nType %s to %s, anything else stops: ' "$want" "$what"
  read -r got || true
  [[ "$got" == "$want" ]] || die "Stopped, nothing was applied."
}

# Lines that set a value and still have the placeholder. Comments don't count.
replace_me_lines() {
  grep -nE '^[[:space:]]*[^#[:space:]][^#]*REPLACE-ME' "$1" || true
}
