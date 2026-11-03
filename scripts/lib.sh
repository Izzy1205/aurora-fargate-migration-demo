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
    # First line is "Terraform v1.17.0". Text, so it works without jq.
    terraform) out=$(terraform version 2>/dev/null | head -n 1) ;;
    terragrunt) out=$(terragrunt --version 2>&1) ;;
    gh) out=$(gh --version 2>&1 | head -n 1) ;;
    jq) out=$(jq --version 2>&1) ;;
    openssl) out=$(openssl version 2>&1) ;;
    *) return 1 ;;
  esac
  grep -oE '[0-9]+(\.[0-9]+)+' <<<"$out" | head -n 1
}

# Where to get a tool. Git Bash on Windows doesn't always see what an
# installer put on the Windows PATH, so it gets its own lines.
install_hint() {
  case "$1" in
    aws) echo "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
    terraform) echo "https://developer.hashicorp.com/terraform/install" ;;
    terragrunt) echo "https://terragrunt.gruntwork.io/docs/getting-started/install/" ;;
    gh) echo "https://cli.github.com/" ;;
    jq) echo "https://jqlang.org/download/" ;;
    openssl) echo "https://openssl-library.org/source/ (Git Bash ships one)" ;;
    *) echo "" ;;
  esac
}

is_git_bash() {
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

git_bash_hint() {
  case "$1" in
    jq)
      echo '    Git Bash: mkdir -p ~/bin && curl -L -o ~/bin/jq.exe https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe'
      ;;
    gh)
      echo '    Git Bash: the installer puts gh in "/c/Program Files/GitHub CLI". Add it with:'
      echo "      echo 'export PATH=\"\$PATH:/c/Program Files/GitHub CLI\"' >> ~/.bashrc && source ~/.bashrc"
      ;;
  esac
}

# require_tools aws terraform jq ...
require_tools() {
  local t v min missing=0 path_note=0
  for t in "$@"; do
    min=$(min_version "$t")
    if ! command -v "$t" >/dev/null 2>&1; then
      warn "$t not found on PATH (need ${min:-any version}). Install: $(install_hint "$t")"
      if is_git_bash; then
        git_bash_hint "$t" >&2
        [[ "$t" != jq ]] || path_note=1
      fi
      missing=1
      continue
    fi
    [[ -n "$min" ]] || continue
    v=$(tool_version "$t" || true)
    if [[ -z "$v" ]]; then
      warn "could not read the $t version. Check that $t --version works."
      missing=1
    elif ! version_ge "$v" "$min"; then
      warn "$t $v is older than $min. Upgrade: $(install_hint "$t")"
      missing=1
    fi
  done
  if ((path_note)); then
    cat >&2 <<'NOTE'
    Git Bash puts ~/bin on the PATH if the folder exists when the window
    opens. If it doesn't, run: echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
    Then open a new Git Bash window, or run: source ~/.bashrc
NOTE
  fi
  ((missing == 0)) || die "Install or upgrade the tools above, then run again."
}

# Project name from terraform/root.hcl.
resolve_project() {
  local p
  p=$(hcl_value project "$REPO_ROOT/terraform/root.hcl")
  [[ -n "$p" ]] || die "Could not read project from terraform/root.hcl"
  printf '%s\n' "$p"
}

BOOT_TFVARS="$REPO_ROOT/terraform/bootstrap/terraform.tfvars"
SB_TFVARS="$REPO_ROOT/terraform/state-bucket/terraform.tfvars"

# Region: AWS_REGION, then aws_region in the given tfvars, then the
# bootstrap's terraform.tfvars, then us-east-2.
resolve_region() {
  local r="${AWS_REGION:-}"
  if [[ -z "$r" && -n "${1:-}" && -f "$1" ]]; then
    r=$(hcl_value aws_region "$1")
  fi
  if [[ -z "$r" && -f "$BOOT_TFVARS" ]]; then
    r=$(hcl_value aws_region "$BOOT_TFVARS")
  fi
  printf '%s\n' "${r:-us-east-2}"
}

# Owner: MIGDEMO_OWNER, then owner in the given tfvars, then the
# bootstrap's terraform.tfvars. Empty if none has a real value.
resolve_owner() {
  local o="${MIGDEMO_OWNER:-}"
  if [[ -z "$o" && -n "${1:-}" && -f "$1" ]]; then
    o=$(hcl_value owner "$1")
  fi
  if [[ (-z "$o" || "$o" == *REPLACE-ME*) && -f "$BOOT_TFVARS" ]]; then
    o=$(hcl_value owner "$BOOT_TFVARS")
  fi
  [[ "$o" == *REPLACE-ME* ]] && o=""
  printf '%s\n' "$o"
}

# Account the credentials are for.
current_account() {
  aws sts get-caller-identity --query Account --output text
}

# Optional account pin: MIGDEMO_ACCOUNT_ID, then expected_account_id in
# terraform/state-bucket/terraform.tfvars. Empty if neither is set.
expected_account() {
  local acct="${MIGDEMO_ACCOUNT_ID:-}"
  if [[ -z "$acct" && -f "$SB_TFVARS" ]]; then
    acct=$(hcl_value expected_account_id "$SB_TFVARS")
  fi
  [[ "$acct" == *REPLACE-ME* ]] && acct=""
  printf '%s\n' "$acct"
}

# Reads the account from sts and sets ACCOUNT_ID. If a pin is set, stops
# unless the credentials are for that account.
check_account() {
  local want have
  have=$(current_account) || die "Could not read the account from aws sts get-caller-identity."
  [[ "$have" =~ ^[0-9]{12}$ ]] || die "aws sts get-caller-identity returned \"$have\", not an account ID."
  want=$(expected_account)
  if [[ -n "$want" ]]; then
    [[ "$want" =~ ^[0-9]{12}$ ]] || die "Account pin \"$want\" is not a 12 digit account ID. Check MIGDEMO_ACCOUNT_ID or expected_account_id."
    [[ "$have" == "$want" ]] || die "Signed in to account $have, expected $want. Sign in to the right account."
    info "Account $have (matches the pin)"
  else
    info "Account $have (no pin set. Set MIGDEMO_ACCOUNT_ID or expected_account_id to lock it.)"
  fi
  ACCOUNT_ID="$have"
  export ACCOUNT_ID
}

# Tagged resources still up in an env, not counting the bootstrap's own
# (ManagedBy=terraform-bootstrap) or IAM. The tag API can list a deleted
# resource for a few minutes, so a hit here isn't proof alone.
env_resources_left() {
  local project="$1" env="$2" region="$3"
  aws resourcegroupstaggingapi get-resources --region "$region" \
    --tag-filters "Key=Project,Values=$project" "Key=Environment,Values=$env" \
    --output json |
    jq -r '.ResourceTagMappingList[]
      | select((.Tags // []) | map(select(.Key == "ManagedBy" and .Value == "terraform-bootstrap")) | length == 0)
      | select(.ResourceARN | contains(":iam::") | not)
      | .ResourceARN'
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
