#!/usr/bin/env bash
# Account and profile lookup per env in lib.sh, with a fake aws and no AWS.
#
#   bash scripts/tests/account-per-env.sh
# shellcheck disable=SC2034,SC2329
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$here/../lib.sh"
set +e

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ACCOUNTS_FILE="$tmp/accounts.hcl"
SB_TFVARS="$tmp/sb.tfvars"
unset MIGDEMO_ACCOUNT_ID MIGDEMO_TESTING_ACCOUNT_ID MIGDEMO_STAGE_ACCOUNT_ID MIGDEMO_PRODUCTION_ACCOUNT_ID
unset MIGDEMO_TESTING_AWS_PROFILE MIGDEMO_STAGE_AWS_PROFILE MIGDEMO_PRODUCTION_AWS_PROFILE AWS_PROFILE

fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  fail=1
}
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else bad "$1 (no '$3' in: $2)"; fi; }

# The fake account follows the profile: prof-<12 digits> signs in there,
# no profile signs in to $DEFAULT_ACCT.
DEFAULT_ACCT=111111111111
aws() {
  case "$1 $2" in
    "sts get-caller-identity")
      if [[ "${AWS_PROFILE:-}" == prof-* ]]; then echo "${AWS_PROFILE#prof-}"; else echo "$DEFAULT_ACCT"; fi
      ;;
    "configure get") return 1 ;;
    *) return 1 ;;
  esac
}
info() { :; }

# Runs in a subshell so die's exit doesn't end the test. Prints stderr too.
try() { ("$@") 2>&1; }

# ---- lookup order ----
rm -f "$ACCOUNTS_FILE" "$SB_TFVARS"
eq "nothing set: no account" "$(env_account stage)" ""
printf 'expected_account_id = "111111111111"\n' >"$SB_TFVARS"
eq "old pin in state-bucket tfvars applies to every env" "$(env_account production)" 111111111111
eq "MIGDEMO_ACCOUNT_ID beats the tfvars pin" "$(MIGDEMO_ACCOUNT_ID=999999999999 env_account stage)" 999999999999
cat >"$ACCOUNTS_FILE" <<'HCL'
locals {
  testing_account_id  = "111111111111"
  stage_account_id    = "222222222222"
  stage_aws_profile   = "prof-222222222222"
  production_account_id = "REPLACE-ME"
}
HCL
eq "accounts.hcl beats the pin" "$(env_account stage)" 222222222222
eq "placeholder in accounts.hcl falls back to the pin" "$(env_account production)" 111111111111
eq "MIGDEMO_<ENV>_ACCOUNT_ID beats accounts.hcl" "$(MIGDEMO_STAGE_ACCOUNT_ID=333333333333 env_account stage)" 333333333333
eq "profile from accounts.hcl" "$(env_profile stage)" prof-222222222222
eq "no profile for testing" "$(env_profile testing)" ""
eq "MIGDEMO_<ENV>_AWS_PROFILE beats accounts.hcl" "$(MIGDEMO_STAGE_AWS_PROFILE=other env_profile stage)" other

# ---- use_env ----
out=$(try use_env testing)
eq "testing in the default session passes" "$?" 0
out=$( (use_env stage >/dev/null && echo "AWS_PROFILE=$AWS_PROFILE ACCOUNT_ID=$ACCOUNT_ID") 2>&1)
eq "stage switches to its profile and account" "$out" "AWS_PROFILE=prof-222222222222 ACCOUNT_ID=222222222222"

out=$( (MIGDEMO_STAGE_AWS_PROFILE=prof-444444444444 use_env stage) 2>&1)
eq "wrong profile for the env stops" "$?" 1
has "wrong profile message names env, accounts and profile" "$out" "stage is in account 222222222222 but profile prof-444444444444 signs in to 444444444444"

out=$( (DEFAULT_ACCT=555555555555 use_env testing) 2>&1)
eq "wrong account with no profile stops" "$?" 1
has "mismatch message says which profile to set" "$out" "testing is in account 111111111111 but you're signed in to 555555555555"
has "mismatch message points at testing_aws_profile" "$out" "testing_aws_profile"

# ---- several envs ----
out=$(try check_multi_account testing stage production)
eq "two accounts, one with no profile: stops" "$?" 1
has "refusal lists envs with no profile" "$out" "no profile for testing production"
out=$(MIGDEMO_TESTING_AWS_PROFILE=prof-111111111111 MIGDEMO_PRODUCTION_AWS_PROFILE=prof-111111111111 try check_multi_account testing stage production)
eq "every env has a profile: goes on" "$?" 0
rm -f "$ACCOUNTS_FILE"
out=$(try check_multi_account testing stage production)
eq "one shared account (today): goes on" "$?" 0
rm -f "$SB_TFVARS"
out=$(try check_multi_account testing stage production)
eq "no accounts set at all: goes on" "$?" 0

# ---- bootstrap's OIDC provider rule ----
eval "$(sed -n '/^shares_testing_account() {/,/^}/p' "$here/../bootstrap.sh")"
declare -F shares_testing_account >/dev/null || bad "shares_testing_account not found in bootstrap.sh"
rm -f "$ACCOUNTS_FILE" "$SB_TFVARS"
if shares_testing_account stage; then pass "no accounts set: stage shares testing's provider (today)"; else bad "no accounts set: stage should share"; fi
printf 'expected_account_id = "111111111111"\n' >"$SB_TFVARS"
if shares_testing_account production; then pass "one pin: production shares testing's provider"; else bad "one pin: production should share"; fi
printf 'locals {\n  testing_account_id = "111111111111"\n  stage_account_id = "222222222222"\n}\n' >"$ACCOUNTS_FILE"
if shares_testing_account stage; then bad "stage in its own account should need its own provider"; else pass "stage in its own account needs its own provider"; fi

exit "$fail"
