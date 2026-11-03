#!/usr/bin/env bash
# Checks how teardown.sh reads a destroy plan, with no AWS and no real
# terragrunt. The fake plan text is what terragrunt 1.2.1 prints on
# Windows Git Bash: a time, "STDOUT terraform:", and color codes.
#
#   bash scripts/tests/teardown-plan-summary.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Pull just the two functions out of teardown.sh so its main part doesn't run.
eval "$(sed -n '/^read_plan() {/,/^}/p;/^strip_log() {/,/^}/p' "$here/../teardown.sh")"
declare -F read_plan strip_log >/dev/null || { echo "read_plan or strip_log not found in teardown.sh"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
env_dir() { echo "$tmp"; }
native_path() { echo "$1"; }

# SHOW is what the fake "terragrunt show -json" prints, or "fail".
SHOW=fail
terragrunt() {
  [[ "$SHOW" == fail ]] && return 1
  printf '%s\n' "$SHOW"
}

line() { printf '\033[90m11:11:30.457\033[m \033[37mSTDOUT\033[m \033[36mterraform: \033[m%b\n' "$1"; }
plan_text() {
  line '  # module.network.aws_vpc.this will be \033[1m\033[31mdestroyed\033[0m'
  line '\033[1mPlan:\033[0m \033[0m0 to add, 0 to change, 44 to destroy.\033[0m'
  line 'Changes to Outputs:'
}
gone_text() {
  line '\033[0m\033[1m\033[32mNo changes.\033[0m\033[1m No objects need to be destroyed.\033[0m'
}
outputs_text() {
  line 'Changes to Outputs:'
  line '  - vpc_id = "vpc-0b3d05a68428ed2af" -> null'
}

fails=0
check() {
  local name="$1" want_gone="$2" want_summary="$3" textfn="$4"
  "$textfn" >"$tmp/out.txt"
  read_plan testing network "$tmp/plan" "$tmp/out.txt"
  if [[ "$PLAN_GONE" == "$want_gone" && "$PLAN_SUMMARY" == *"$want_summary"* ]]; then
    echo "ok    $name: $PLAN_SUMMARY"
  else
    echo "FAIL  $name: gone=$PLAN_GONE summary=$PLAN_SUMMARY (wanted gone=$want_gone, $want_summary)"
    fails=1
  fi
}

SHOW=fail
check "text, prefixed Plan line" 0 "44 to destroy" plan_text
check "text, prefixed No changes" 1 "No changes." gone_text
check "text, outputs only" 0 "could not read the plan" outputs_text

SHOW='{"resource_changes":[{"change":{"actions":["delete"]}},{"change":{"actions":["no-op"]}}]}'
check "json, one delete" 0 "1 to destroy" plan_text
SHOW='{"format_version":"1.2","applyable":false}'
check "json, empty" 1 "No changes." gone_text
SHOW='{"resource_changes":[],"output_changes":{"vpc_id":{"actions":["delete"]}}}'
check "json, outputs only" 0 "only outputs left" outputs_text
# Prefixed log text instead of JSON falls back to the text.
SHOW=$(line 'not json')
check "json junk, falls back to text" 0 "44 to destroy" plan_text

((fails == 0)) && echo "All good." || exit 1
