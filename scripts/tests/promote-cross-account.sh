#!/usr/bin/env bash
# Shape checks for promote.yml same-account / cross-account promote.
#
#   bash scripts/tests/promote-cross-account.sh
# ${{ }} and $src_* are literal needles, not shell expansions.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."
wf=.github/workflows/promote.yml

fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
has() {
  if grep -qF "$2" "$1"; then pass "$3"
  else bad "$3 (missing in $1: $2)"; fi
}
has_re() {
  if grep -Eq "$2" "$1"; then pass "$3"
  else bad "$3 (no /$2/ in $1)"; fi
}

has "$wf" 'environment: ${{ needs.setup.outputs.source }}-infra-plan' \
  'resolve uses the source infra-plan environment'
has "$wf" 'env: ${{ needs.setup.outputs.source }}' \
  'check-role validates the source plan role'
has "$wf" 'source_registry: ${{ steps.src.outputs.source_registry }}' \
  'resolve exports source_registry'
has "$wf" 'SRC_REGISTRY: ${{ needs.resolve.outputs.source_registry }}' \
  'copy takes source_registry from resolve'
has "$wf" 'skopeo login --username AWS --password-stdin' \
  'copy logs into registries with skopeo login'
has "$wf" 'skopeo copy --all --preserve-digests --retry-times 3' \
  'copy uses --all --preserve-digests'
has_re "$wf" 'docker://\$src_registry/\$src_repo@\$digest' \
  'copy source is src_registry@digest'
has_re "$wf" 'docker://\$dst_registry/\$dst_repo:\$SHA' \
  'copy dest is dst_registry:SHA'
has "$wf" 'source registry:' \
  'summary mentions source registry'
has "$wf" 'target registry:' \
  'summary mentions target registry'

# First environment: after "resolve:" must be source.
resolve_env=$(awk '
  /^  resolve:/ {inr=1}
  inr && /environment:/ {print; exit}
' "$wf")
if [[ "$resolve_env" == *'outputs.source }}-infra-plan'* ]]; then
  pass 'first resolve environment is source-infra-plan'
else
  bad "resolve environment is not source: $resolve_env"
fi

# OIDC: account-aware ARNs, no service read on deploy.
oidc=terraform/modules/github_oidc
has "$oidc/variables.tf" 'variable "promote_from_account_id"' \
  'github_oidc has promote_from_account_id'
has "$oidc/main.tf" 'promote_from_account = var.promote_from_account_id' \
  'promote_from_account local uses the var'
if grep -q 'PromotionSourceServiceRead' "$oidc/roles.tf"; then
  bad 'PromotionSourceServiceRead still in roles.tf'
else
  pass 'PromotionSourceServiceRead dropped from deploy role'
fi
has "$oidc/roles.tf" 'PromotionSourcePull' \
  'PromotionSourcePull kept'
has terraform/bootstrap/main.tf 'promote_from_account_id = var.promote_from_account_id' \
  'bootstrap passes promote_from_account_id'

# Registry: empty pull_principals = no policy.
reg=terraform/modules/registry
has "$reg/variables.tf" 'variable "pull_principals"' \
  'registry has pull_principals'
has "$reg/main.tf" 'resource "aws_ecr_repository_policy" "pull"' \
  'registry can create a pull policy'
has "$reg/main.tf" 'length(var.pull_principals) == 0 ? null' \
  'empty pull_principals skips the policy'
has terraform/layers/app/main.tf 'pull_principals = var.ecr_pull_principals' \
  'app layer wires ecr_pull_principals'
has terraform/layers/app/variables.tf 'default     = []' \
  'ecr_pull_principals defaults empty'

# No live foreign role ARNs committed.
if grep -RInE 'arn:aws:iam::[0-9]{12}:role/' terraform/layers terraform/environments/_envcommon 2>/dev/null \
  | grep -viE 'example|REPLACE|111111111111|222222222222|test'; then
  bad 'live IAM role ARN found in app wiring'
else
  pass 'no live foreign role ARNs in app wiring'
fi

has docs/adr/0001-account-per-env.md '## PR 3: ECR promote' \
  'ADR has PR 3 section'

exit "$fail"
