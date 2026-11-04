#!/usr/bin/env bash
# bootstrap.sh org: a plan with only output changes still applies, accounts
# already in the OU are skipped, and a dry run lists pending moves. Fake
# terraform and aws, no AWS.
#
#   bash scripts/tests/org-moves.sh
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
hasnt() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else bad "$1 ('$3' in: $2)"; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ORG_DIR="$tmp/org"
mkdir -p "$ORG_DIR"
CLEANUP=()
calls="$tmp/calls"

# State has ou_account_ids = [], the plan has the new list as an output
# change only. Apply copies the plan's outputs into state.
plan_json() {
  cat <<J
{"resource_changes":[{"address":"aws_organizations_organizational_unit.demo","change":{"actions":["no-op"]}}],
 "output_changes":{"ou_id":{"actions":["no-op"]},"ou_account_ids":{"actions":["$1"]}},
 "planned_values":{"outputs":{"ou_id":{"value":"ou-test"},"ou_account_ids":{"value":$2}}}}
J
}
reset() {
  : >"$calls"
  echo '[]' >"$tmp/state_ids"
  plan_json "$1" "$2" >"$tmp/plan.json"
}

tf_in() {
  shift 2
  echo "terraform $*" >>"$calls"
  case "$1" in
    show) cat "$tmp/plan.json" ;;
    apply) jq -c '.planned_values.outputs.ou_account_ids.value' "$tmp/plan.json" >"$tmp/state_ids" ;;
    output)
      case "$3" in
        ou_id) echo ou-test ;;
        ou_account_ids) cat "$tmp/state_ids" ;;
      esac
      ;;
  esac
}

# 222222222222 sits under the root, 333333333333 is already in the OU.
aws() {
  echo "aws $*" >>"$calls"
  case "$1 $2" in
    "organizations list-parents")
      if [[ "$4" == 333333333333 ]]; then echo ou-test; else echo r-test; fi
      ;;
    "organizations list-policies-for-target")
      if [[ "$*" == *Policies[].Id* ]]; then printf 'p-FullAWSAccess\tp-other\n'; else echo RootPolicy; fi
      ;;
  esac
}
confirm() { echo "confirm $1" >>"$calls"; }
preflight_common() { :; }
check_tfvars_file() { :; }
hcl_value() { :; }
ensure_session() { :; }
org_caller_check() { :; }

for fn in summarize_plan org_move_accounts cmd_org; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$here/../bootstrap.sh")"
  declare -F "$fn" >/dev/null || bad "$fn not found in bootstrap.sh"
done

try() { (exec 2>&1 && "$@"); }

# Output-only change: confirm org, apply, then move the new account.
reset update '["222222222222","333333333333"]'
DRY_RUN=0
out=$(try cmd_org)
c=$(cat "$calls")
has "output-only change: asks to apply" "$c" "confirm org"
has "output-only change: applies" "$c" "terraform apply"
hasnt "output-only change: no 'No changes.'" "$out" "No changes."
has "output-only change: lists the output" "$out" "output.ou_account_ids"
has "output-only change: moves the new account" "$c" "move-account --account-id 222222222222 --source-parent-id r-test --destination-parent-id ou-test"
has "output-only change: asks before the move" "$c" "confirm move"
has "already in the OU: skipped" "$out" "333333333333 is already in ou-test"
hasnt "already in the OU: not moved" "$c" "move-account --account-id 333333333333"

# Nothing changed and everything is in place: no apply, no move.
reset no-op '["333333333333"]'
echo '["333333333333"]' >"$tmp/state_ids"
out=$(try cmd_org)
c=$(cat "$calls")
hasnt "no changes: no apply" "$c" "terraform apply"
has "no changes: says so" "$out" "No changes."
has "no changes: account already in" "$out" "333333333333 is already in ou-test"
hasnt "no changes: no move" "$c" "move-account"

# Dry run: list pending moves from the plan, read-only.
reset update '["222222222222","333333333333"]'
DRY_RUN=1
out=$(try cmd_org)
c=$(cat "$calls")
has "dry run: lists the pending move" "$out" "Would move 222222222222 from r-test into ou-test"
has "dry run: already in the OU" "$out" "333333333333 is already in ou-test"
hasnt "dry run: no apply" "$c" "terraform apply"
hasnt "dry run: no move" "$c" "move-account"
hasnt "dry run: no confirm" "$c" "confirm"

# Dry run before the OU exists: ou_id is unknown in the plan.
reset update '["222222222222"]'
jq '.planned_values.outputs.ou_id = {}' "$tmp/plan.json" >"$tmp/p" && mv "$tmp/p" "$tmp/plan.json"
out=$(try cmd_org)
has "dry run, new OU: says it would move" "$out" "Would move 222222222222 from r-test into the new OU"

exit "$fail"
