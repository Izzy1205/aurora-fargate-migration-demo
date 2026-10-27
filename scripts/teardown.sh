#!/usr/bin/env bash
# Tears down one environment, newest layer first.
# Shows each destroy plan and waits for a "yes" before applying it.
# Run from the repo root with admin credentials, e.g.:
#   ./scripts/teardown.sh testing
set -euo pipefail

env="${1:-testing}"

# Same values the pipeline uses. Fail early if any are missing.
: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET}"
: "${MIGDEMO_OWNER:?set MIGDEMO_OWNER}"
: "${MIGDEMO_BUDGET_EMAIL:?set MIGDEMO_BUDGET_EMAIL}"
: "${MIGDEMO_ALB_INGRESS_CIDRS:?set MIGDEMO_ALB_INGRESS_CIDRS}"
export MIGDEMO_MOCKS_ON_PLAN=false

cd "terraform/environments/$env"

# Git Bash needs a Windows path for terraform.exe; plain pwd elsewhere.
here=$(pwd -W 2>/dev/null || pwd)

for unit in observability app data network; do
  plan="$here/$unit.destroy.tfplan"
  echo "=== $env/$unit: destroy plan ==="
  terragrunt run --working-dir "$unit" -- plan -destroy -out="$plan"

  read -r -p "Destroy $env/$unit? Type yes to continue: " answer
  if [ "$answer" != "yes" ]; then
    echo "Stopped at $env/$unit. Nothing else was destroyed."
    rm -f "$unit.destroy.tfplan"
    exit 1
  fi

  terragrunt run --working-dir "$unit" -- apply "$plan"
  rm -f "$unit.destroy.tfplan"
done

echo "Done. Check the teardown list in the README."