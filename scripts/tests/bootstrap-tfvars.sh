#!/usr/bin/env bash
# Checks how bootstrap.sh picks each env's tfvars, with no AWS. Testing's
# file used to be terraform.tfvars, which terraform loads on its own, so
# stage and production got its values too. Now every env gets only its own
# file with -var-file. This checks the rename of the old file, the stop when
# stage or production would lose a value they used to get from testing, and
# (with terraform installed) that terraform ends up with the same variable
# values both ways.
#
#   bash scripts/tests/bootstrap-tfvars.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$here/../lib.sh"

# Pull just these functions out of bootstrap.sh so its main part doesn't run.
eval "$(awk '
  BEGIN { n = split("env_tfvars tfvar env_state_key migrate_legacy_tfvars check_inherited", a, " ")
          for (i = 1; i <= n; i++) want[a[i] "() {"] = 1 }
  !inside { for (k in want) if (index($0, k) == 1) { print; if ($0 !~ /}$/) inside = 1; next } ; next }
  { print; if ($0 == "}") inside = 0 }
' "$here/../bootstrap.sh")"
for f in env_tfvars tfvar env_state_key migrate_legacy_tfvars check_inherited; do
  declare -F "$f" >/dev/null || { echo "$f not found in bootstrap.sh"; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2034 # read by env_state_key from bootstrap.sh
DEFAULT_KEY_PREFIX="aurora-fargate-migration-demo"

fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() {
  printf 'FAIL %s\n' "$1"
  fail=1
}

TESTING='aws_region                  = "us-east-2"
owner                       = "izzy"
github_repo                 = "someone/aurora-fargate-migration-demo"
state_bucket_name           = "someone-migdemo-tfstate-2026"
create_github_oidc_provider = true
state_key_prefix            = "demo-states"
github_subject_prefixes = [
  "repo:someone@1/aurora-fargate-migration-demo@2",
]'

stage_body() {
  printf '%s\n' 'aws_region  = "us-east-2"
owner       = "izzy"
environment = "stage"
github_repo = "someone/aurora-fargate-migration-demo"
state_bucket_name = "someone-migdemo-tfstate-2026"
create_github_oidc_provider = false
github_plan_environment  = "stage-infra-plan"
github_infra_environment = "stage-infra"
github_app_environment   = "stage-app"'
}

# A fresh repo root with terraform/bootstrap in it. $1 is the testing
# file name, terraform.tfvars for the old layout.
setup() {
  REPO_ROOT="$tmp/$1-$RANDOM"
  BOOT_DIR="$REPO_ROOT/terraform/bootstrap"
  LEGACY_TFVARS="$BOOT_DIR/terraform.tfvars"
  BOOT_TFVARS="$BOOT_DIR/testing.tfvars"
  mkdir -p "$BOOT_DIR"
  printf '%s\n' "$TESTING" >"$BOOT_DIR/$1"
}

# ---- rename of the old file ----

setup terraform.tfvars
if (migrate_legacy_tfvars <<<yes >/dev/null 2>&1) &&
  [[ ! -f "$LEGACY_TFVARS" && "$(cat "$BOOT_DIR/testing.tfvars")" == "$TESTING" ]]; then
  pass "old terraform.tfvars is renamed to testing.tfvars after yes"
else
  bad "old terraform.tfvars is renamed to testing.tfvars after yes"
fi

setup terraform.tfvars
if ! (migrate_legacy_tfvars <<<no >/dev/null 2>&1) && [[ -f "$LEGACY_TFVARS" && ! -f "$BOOT_DIR/testing.tfvars" ]]; then
  pass "anything but yes stops and leaves the old file alone"
else
  bad "anything but yes stops and leaves the old file alone"
fi

setup terraform.tfvars
echo 'owner = "other"' >"$BOOT_DIR/testing.tfvars"
out=$(migrate_legacy_tfvars <<<yes 2>&1) && rc=0 || rc=$?
if ((rc != 0)) && [[ "$out" == *"Both"* && -f "$LEGACY_TFVARS" && "$(cat "$BOOT_DIR/testing.tfvars")" == 'owner = "other"' ]]; then
  pass "both files there stops and touches neither"
else
  bad "both files there stops and touches neither"
fi

setup testing.tfvars
if (migrate_legacy_tfvars </dev/null >/dev/null 2>&1); then
  pass "no old file, nothing to do"
else
  bad "no old file, nothing to do"
fi

# ---- values stage used to get from testing's file ----

setup testing.tfvars
stage_body >"$BOOT_DIR/stage.tfvars"
out=$(check_inherited stage 2>&1) && rc=0 || rc=$?
if ((rc != 0)) && [[ "$out" == *github_subject_prefixes* && "$out" == *state_key_prefix* && "$out" != *owner* ]]; then
  pass "stage missing values testing sets stops and names them"
else
  bad "stage missing values testing sets stops and names them: $out"
fi

{
  stage_body
  echo 'state_key_prefix = "demo-states"'
  echo 'github_subject_prefixes = ["repo:someone@1/aurora-fargate-migration-demo@2"]'
} >"$BOOT_DIR/stage.tfvars"
if (check_inherited stage >/dev/null 2>&1) && (check_inherited testing >/dev/null 2>&1); then
  pass "stage that sets everything testing sets goes on"
else
  bad "stage that sets everything testing sets goes on"
fi

if [[ "$(env_state_key testing)" == demo-states/bootstrap.tfstate &&
  "$(env_state_key stage)" == demo-states/bootstrap-stage.tfstate ]]; then
  pass "state keys come from each env's own file"
else
  bad "state keys come from each env's own file: $(env_state_key testing) $(env_state_key stage)"
fi

# ---- what terraform resolves, old layout vs new ----

# Variable values terraform would use, from a plan of the bootstrap's
# variables.tf alone. No providers, no backend, no AWS.
resolved() {
  local dir="$1" data
  shift
  data="$dir/.tf-$RANDOM"
  cp "$here/../../terraform/bootstrap/variables.tf" "$dir/"
  (cd "$dir" && TF_DATA_DIR="$data" terraform init -input=false >/dev/null &&
    TF_DATA_DIR="$data" terraform plan -refresh=false -input=false -out=p "$@" >/dev/null &&
    TF_DATA_DIR="$data" terraform show -json p) | jq -S .variables
  rm -f "$dir/p"
}

if ! command -v terraform >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    bad "terraform not installed"
  else
    echo "skip terraform checks, terraform not installed"
  fi
else
  stage_extra=$(
    stage_body
    echo 'state_key_prefix = "demo-states"'
    echo 'github_subject_prefixes = ["repo:someone@1/aurora-fargate-migration-demo@2"]'
  )
  old="$tmp/old"
  new="$tmp/new"
  mkdir -p "$old" "$new"
  printf '%s\n' "$TESTING" >"$old/terraform.tfvars"
  printf '%s\n' "$TESTING" >"$new/testing.tfvars"
  printf '%s\n' "$stage_extra" >"$old/stage.tfvars"
  printf '%s\n' "$stage_extra" >"$new/stage.tfvars"

  [[ "$(resolved "$new" -var-file=testing.tfvars | jq -r .owner.value)" == izzy ]] ||
    bad "terraform plan of variables.tf gave no values"

  # Old: testing had no -var-file and terraform.tfvars loaded under stage too.
  if [[ "$(resolved "$old")" == "$(resolved "$new" -var-file=testing.tfvars)" ]]; then
    pass "testing gets the same values as before"
  else
    bad "testing gets the same values as before"
  fi
  if [[ "$(resolved "$old" -var-file=stage.tfvars)" == "$(resolved "$new" -var-file=stage.tfvars)" ]]; then
    pass "stage gets the same values as before"
  else
    bad "stage gets the same values as before"
  fi

  # The case check_inherited is there for: without it stage would quietly
  # drop testing's values.
  stage_body >"$old/stage.tfvars"
  stage_body >"$new/stage.tfvars"
  was=$(resolved "$old" -var-file=stage.tfvars | jq -c '[.github_subject_prefixes.value, .state_key_prefix.value]')
  now=$(resolved "$new" -var-file=stage.tfvars | jq -c '[.github_subject_prefixes.value, .state_key_prefix.value]')
  if [[ "$was" == '[["repo:someone@1/aurora-fargate-migration-demo@2"],"demo-states"]' &&
    "$now" == '[[],"aurora-fargate-migration-demo"]' ]]; then
    pass "a stage file missing testing's values would change, which check_inherited stops"
  else
    bad "a stage file missing testing's values would change, which check_inherited stops"
  fi
fi

exit "$fail"
