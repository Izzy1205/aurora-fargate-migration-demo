#!/usr/bin/env bash
# Renders every unit with terragrunt (no AWS) and checks the backend and
# provider match fixtures/render-main.jsonl, which was rendered from main
# before the account map. Then adds an accounts.hcl to a copy and checks the
# backend still matches and only the provider gains allowed_account_ids.
# Needs terragrunt, so CI runs it in the terraform job.
#
#   bash scripts/tests/backend-render.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
want="$here/fixtures/render-main.jsonl"

command -v terragrunt >/dev/null 2>&1 || {
  echo "terragrunt not found, skipping"
  exit 0
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/terraform"
cp "$root/terraform/root.hcl" "$tmp/terraform/"
cp -R "$root/terraform/environments" "$tmp/terraform/"
find "$tmp/terraform" -name .terragrunt-cache -prune -exec rm -rf {} +

fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  fail=1
}

# Same values the fixture was made with. No state-bucket tfvars in the copy.
render_all() {
  local e u
  for e in testing stage production; do
    for u in network data app observability; do
      env -u TF_STATE_KMS_KEY -u TF_STATE_REGION \
        -u MIGDEMO_TESTING_ACCOUNT_ID -u MIGDEMO_STAGE_ACCOUNT_ID -u MIGDEMO_PRODUCTION_ACCOUNT_ID \
        TF_STATE_BUCKET=example-tfstate MIGDEMO_OWNER=ci MIGDEMO_BUDGET_EMAIL=ci@example.com \
        MIGDEMO_ALB_INGRESS_CIDRS='["203.0.113.1/32"]' MIGDEMO_MOCKS_ON_PLAN=true \
        terragrunt render --format json --non-interactive \
        --working-dir "$tmp/terraform/environments/$e/$u" 2>"$tmp/err" |
        jq -c --arg u "$e/$u" '{unit:$u, remote_state:.remote_state.config, provider:.generate.provider.contents}' ||
        { cat "$tmp/err" >&2; return 1; }
    done
  done
}

render_all >"$tmp/now.jsonl" || bad "render without accounts.hcl"
if diff <(sort "$want") <(sort "$tmp/now.jsonl") >"$tmp/diff"; then
  pass "no accounts.hcl: backend and provider same as main for all 12 units"
else
  bad "no accounts.hcl: render differs from main"
  cat "$tmp/diff"
fi

cat >"$tmp/terraform/accounts.hcl" <<'HCL'
locals {
  testing_account_id    = "111111111111"
  stage_account_id      = "222222222222"
  production_account_id = "REPLACE-ME"
}
HCL
render_all >"$tmp/map.jsonl" || bad "render with accounts.hcl"
if diff <(jq -c '{unit, remote_state}' "$want" | sort) <(jq -c '{unit, remote_state}' "$tmp/map.jsonl" | sort) >"$tmp/diff"; then
  pass "with accounts.hcl: backend same as main for all 12 units"
else
  bad "with accounts.hcl: backend differs"
  cat "$tmp/diff"
fi

guard() { jq -r --arg u "$1" 'select(.unit == $u) | .provider' "$tmp/map.jsonl" | sed -n 's/.*allowed_account_ids = \["\([0-9]*\)"\].*/\1/p'; }
if [[ "$(guard testing/app)" == 111111111111 ]]; then pass "testing provider pinned to its account"; else bad "testing provider guard: '$(guard testing/app)'"; fi
if [[ "$(guard stage/data)" == 222222222222 ]]; then pass "stage provider pinned to its account"; else bad "stage provider guard: '$(guard stage/data)'"; fi
if [[ -z "$(guard production/network)" ]]; then pass "placeholder account adds no guard"; else bad "production got a guard: '$(guard production/network)'"; fi

exit "$fail"
