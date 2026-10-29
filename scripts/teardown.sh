#!/usr/bin/env bash
# Tears down one env, newest layer first, asking before each destroy.
# Usage: ./scripts/teardown.sh testing
set -euo pipefail

env="${1:-testing}"
env_dir="terraform/environments/$env"

[ -f "$env_dir/env.hcl" ] || { echo "No $env_dir/env.hcl. Run from the repo root." >&2; exit 1; }

: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET}"
: "${MIGDEMO_OWNER:?set MIGDEMO_OWNER}"
: "${MIGDEMO_BUDGET_EMAIL:?set MIGDEMO_BUDGET_EMAIL}"
: "${MIGDEMO_ALB_INGRESS_CIDRS:?set MIGDEMO_ALB_INGRESS_CIDRS}"

# Read from the same files Terragrunt uses.
hcl_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2" | head -n 1
}
project=$(hcl_value project terraform/root.hcl)
region=$(hcl_value aws_region "$env_dir/env.hcl")
: "${project:?could not read project from terraform/root.hcl}"
: "${region:?could not read aws_region from $env_dir/env.hcl}"
echo "Project: $project  Environment: $env  Region: $region"

echo "Signing in fresh so the session lasts the whole run..."
aws login || exit 1

# Stop if nothing is tagged for this env. Usually the wrong env, region, or account.
found=$(aws resourcegroupstaggingapi get-resources --region "$region" \
  --tag-filters "Key=Project,Values=$project" "Key=Environment,Values=$env" \
  --query 'length(ResourceTagMappingList)' --output text)
if [ "$found" = "0" ]; then
  echo "No resources tagged Project=$project Environment=$env in $region. Nothing to tear down." >&2
  exit 1
fi
echo "Found $found tagged resources."

export MIGDEMO_MOCKS_ON_PLAN=false
cd "$env_dir"

# Git Bash needs a Windows path for terraform.exe.
here=$(pwd -W 2>/dev/null || pwd)

for unit in observability app data network; do
  aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS session expired before $unit. Run aws login and rerun." >&2; exit 1; }
  plan="$here/$unit.destroy.tfplan"
  echo "=== $env/$unit: destroy plan ==="
  terragrunt run --working-dir "$unit" -- plan -destroy -out="$plan"

  read -r -p "Destroy $env/$unit? Type yes to continue: " answer
  if [ "$answer" != "yes" ]; then
    echo "Stopped at $env/$unit. Nothing else was destroyed."
    rm -f "$plan"
    exit 1
  fi

  terragrunt run --working-dir "$unit" -- apply "$plan"
  rm -f "$plan"
done

echo "Done. Check the teardown list in the README."