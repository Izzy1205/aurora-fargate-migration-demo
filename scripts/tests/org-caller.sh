#!/usr/bin/env bash
# bootstrap.sh org only runs from the management account. Fake aws, no AWS.
#
#   bash scripts/tests/org-caller.sh
# shellcheck disable=SC2034,SC2329
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$here/../lib.sh"
set +e

fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  fail=1
}
has() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else bad "$1 (no '$3' in: $2)"; fi; }

# FAKE_ACCT is who we're signed in as, FAKE_MASTER the org's management
# account. An empty FAKE_MASTER means describe-organization fails.
FAKE_ACCT=111111111111
FAKE_MASTER=111111111111
aws() {
  case "$1 $2" in
    "sts get-caller-identity") echo "$FAKE_ACCT" ;;
    "organizations describe-organization")
      [[ -n "$FAKE_MASTER" ]] || return 254
      echo "$FAKE_MASTER"
      ;;
    *) return 1 ;;
  esac
}

eval "$(sed -n '/^org_caller_check() {/,/^}/p' "$here/../bootstrap.sh")"
declare -F org_caller_check >/dev/null || bad "org_caller_check not found in bootstrap.sh"

try() { (exec 2>&1 && "$@"); }

out=$(try org_caller_check 111111111111)
rc=$?
if ((rc == 0)); then pass "management account: goes on"; else bad "management account should pass: $out"; fi

FAKE_ACCT=222222222222
FAKE_MASTER=111111111111
out=$(try org_caller_check 111111111111)
rc=$?
if ((rc != 0)); then pass "member account: stops"; else bad "member account should stop"; fi
has "member account: says which account it got" "$out" "Signed in to 222222222222"
has "member account: says to set aws_profile" "$out" "aws_profile"

FAKE_ACCT=222222222222
FAKE_MASTER=""
out=$(try org_caller_check 222222222222)
rc=$?
if ((rc != 0)); then pass "tfvars names a member account: stops"; else bad "a member account named in tfvars should stop"; fi
has "tfvars names a member account: says why" "$out" "Can't read the organization"

FAKE_ACCT=222222222222
FAKE_MASTER=111111111111
out=$(try org_caller_check 222222222222)
rc=$?
if ((rc != 0)); then pass "account is not the org's management account: stops"; else bad "should stop when the org's management account differs"; fi
has "not the management account: names the real one" "$out" "management account is 111111111111"

out=$(try org_caller_check REPLACE-ME)
rc=$?
if ((rc != 0)); then pass "placeholder id: stops"; else bad "placeholder id should stop"; fi
has "placeholder id: says 12 digits" "$out" "12 digit"

exit "$fail"
