#!/usr/bin/env bash
# Tears down one environment or all of them: the four Terragrunt units
# under terraform/environments/<env>, newest layer first. Never touches
# terraform/bootstrap or the state bucket. Run from a machine with admin
# creds, never from CI. See --help.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

# Newest layer first. app reads data and network outputs, so it goes
# before them, and network goes last.
UNITS=(observability app data network)
# Downstream first: production promotes from stage, stage from testing.
TEARDOWN_ORDER=(production stage testing)

usage() {
  cat <<'USAGE'
Usage:
  scripts/teardown.sh <testing|stage|production|all> [--dry-run]

  testing|stage|production  Destroy that env's four units: observability,
                            app, data, network.
  all                       production, then stage, then testing. Envs with
                            nothing up are skipped.

Options:
  --dry-run     Sign in, preflight and destroy plans only. Nothing destroyed.
  -h, --help    Show this help.

One run does:
  - preflight: tool versions, AWS session, account, region and how many
    tagged resources each env has
  - a destroy plan for every unit, with a summary
  - list active AWS Backup jobs on the env's vaults
  - one typed confirmation (the env name, or all)
  - apply the saved plans in order, checking the AWS session before each
    unit, and stop at the first failure. Before data, stop any active
    backup jobs and wait until they end (MIGDEMO_BACKUP_WAIT_SECONDS,
    default 1200), since a vault with a running job can't be deleted.
  - check that nothing is left: RDS, ALB, ECS, VPC endpoints, VPC, WAF.
    Exits non-zero if anything is.

Values the units need, read from the environment first:
  TF_STATE_BUCKET            else state_bucket_name in terraform/bootstrap/testing.tfvars
  MIGDEMO_OWNER              else owner in terraform/bootstrap/testing.tfvars
  MIGDEMO_BUDGET_EMAIL       else the BUDGET_EMAIL repo variable (gh)
  MIGDEMO_ALB_INGRESS_CIDRS  else the ALB_INGRESS_CIDRS repo variable (gh)
  MIGDEMO_ACCOUNT_ID         optional account pin, same as bootstrap.sh

The bootstrap (CI roles) and the state bucket stay. To retire an env for
good, run scripts/bootstrap.sh destroy <env> after this.

Every run is logged to logs/<timestamp>-teardown-<target>.log (gitignored).
USAGE
}

# ---- args ----

TARGET=""
DRY_RUN=0

while (($#)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --dry-run) DRY_RUN=1 ;;
    -*)
      usage >&2
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      else
        usage >&2
        die "Unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

case "$TARGET" in
  testing | stage | production)
    TARGETS=("$TARGET")
    ;;
  all)
    TARGETS=("${TEARDOWN_ORDER[@]}")
    ;;
  "")
    usage >&2
    exit 2
    ;;
  *)
    usage >&2
    die "Unknown target: $TARGET. Use testing, stage, production or all."
    ;;
esac

[[ "${GITHUB_ACTIONS:-}" != true ]] || die "teardown.sh runs by hand only, not from CI."

# ---- helpers ----

# Saved plans are removed on any exit, so a stopped run never leaves one
# behind to be applied later by mistake.
CLEANUP=()
cleanup() {
  local f
  for f in ${CLEANUP[@]+"${CLEANUP[@]}"}; do rm -f "$f"; done
}
trap cleanup EXIT

env_dir() { printf '%s\n' "$REPO_ROOT/terraform/environments/$1"; }

env_region() {
  local r
  r=$(hcl_value aws_region "$(env_dir "$1")/env.hcl")
  [[ -n "$r" ]] || die "Could not read aws_region from terraform/environments/$1/env.hcl"
  printf '%s\n' "$r"
}

# Envs that promote from this one and would be stranded without it.
downstream_of() {
  case "$1" in
    testing) echo "stage production" ;;
    stage) echo "production" ;;
    *) echo "" ;;
  esac
}

# Git Bash needs a Windows path for terraform.exe. Plain path elsewhere.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

repo_var() {
  local repo="$1" name="$2"
  [[ -n "$repo" ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  gh variable get "$name" --repo "$repo" 2>/dev/null || true
}

# The same values the pipeline passes to Terragrunt. A destroy still needs
# them, since every variable has to be set to plan.
resolve_inputs() {
  local repo=""
  [[ -f "$BOOT_TFVARS" ]] && repo=$(hcl_value github_repo "$BOOT_TFVARS")
  [[ "$repo" == *REPLACE-ME* ]] && repo=""

  if [[ -z "${TF_STATE_BUCKET:-}" && -f "$BOOT_TFVARS" ]]; then
    TF_STATE_BUCKET=$(hcl_value state_bucket_name "$BOOT_TFVARS")
  fi
  if [[ -z "${TF_STATE_BUCKET:-}" && -f "$SB_TFVARS" ]]; then
    TF_STATE_BUCKET=$(hcl_value bucket_name "$SB_TFVARS")
  fi
  MIGDEMO_OWNER=$(resolve_owner "")
  [[ -n "${MIGDEMO_BUDGET_EMAIL:-}" ]] || MIGDEMO_BUDGET_EMAIL=$(repo_var "$repo" BUDGET_EMAIL)
  [[ -n "${MIGDEMO_ALB_INGRESS_CIDRS:-}" ]] || MIGDEMO_ALB_INGRESS_CIDRS=$(repo_var "$repo" ALB_INGRESS_CIDRS)

  local missing=0
  [[ -n "${TF_STATE_BUCKET:-}" && "$TF_STATE_BUCKET" != *REPLACE-ME* ]] || {
    warn "No state bucket. Set TF_STATE_BUCKET or state_bucket_name in terraform/bootstrap/testing.tfvars."
    missing=1
  }
  [[ -n "$MIGDEMO_OWNER" ]] || {
    warn "No owner. Set MIGDEMO_OWNER or owner in terraform/bootstrap/testing.tfvars."
    missing=1
  }
  [[ -n "${MIGDEMO_BUDGET_EMAIL:-}" ]] || {
    warn "No budget email. Set MIGDEMO_BUDGET_EMAIL, or sign in to gh so it can read the BUDGET_EMAIL repo variable."
    missing=1
  }
  [[ -n "${MIGDEMO_ALB_INGRESS_CIDRS:-}" ]] || {
    warn "No ALB CIDRs. Set MIGDEMO_ALB_INGRESS_CIDRS, or sign in to gh so it can read the ALB_INGRESS_CIDRS repo variable."
    missing=1
  }
  ((missing == 0)) || die "Set the values above, then run again."

  export TF_STATE_BUCKET MIGDEMO_OWNER MIGDEMO_BUDGET_EMAIL MIGDEMO_ALB_INGRESS_CIDRS
  # Mocks on plan, so a rerun after a half finished teardown can still plan
  # a unit whose upstream is already gone. Terragrunt only uses a mock when
  # the dependency has no outputs. A unit that still has resources always
  # has its upstream up (units go newest first), so its plan gets real
  # outputs. A unit with nothing left plans "No changes" and isn't applied.
  export MIGDEMO_MOCKS_ON_PLAN=true
  export TG_NON_INTERACTIVE=true
}

# Checks the session before each unit. If it ran out, sign in again and
# make sure it's still the same account before going on.
session_check() {
  local have
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    warn "AWS session expired. Signing in again before $1."
    session_refresh
  fi
  have=$(current_account) || die "Could not read the account before $1."
  [[ "$have" == "$ACCOUNT_ID" ]] || die "Now signed in to account $have, started in $ACCOUNT_ID. Stopped before $1."
}

plan_file() { printf '%s\n' "$(env_dir "$1")/$2.destroy.tfplan"; }

# Reads a saved plan. Sets PLAN_SUMMARY and PLAN_GONE (1 only when the
# plan is sure to have nothing in it). Tries show -json first, then the
# plan text. Terragrunt puts a time and "STDOUT terraform:" in front of
# every line and both carry color codes, so the text match strips those
# and doesn't care where in the line it is. If neither works the unit
# counts as not gone, so it still gets applied.
read_plan() {
  local env="$1" unit="$2" plan="$3" out="$4" json counts text
  PLAN_SUMMARY="" PLAN_GONE=0

  if json=$(terragrunt run --tf-forward-stdout \
    --working-dir "$(native_path "$(env_dir "$env")/$unit")" -- \
    show -json "$(native_path "$plan")" 2>/dev/null) &&
    counts=$(jq -er '
      [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $c
      | [.output_changes // {} | to_entries[] | select(.value.actions != ["no-op"])] as $o
      | "\($c | map(select(.change.actions | index("delete"))) | length) \($c | length) \($o | length)"
    ' <<<"$json" 2>/dev/null); then
    local deletes changes outputs
    read -r deletes changes outputs <<<"$counts"
    if ((changes == 0 && outputs == 0)); then
      PLAN_SUMMARY="No changes. Nothing left to destroy."
      PLAN_GONE=1
    elif ((changes == 0)); then
      PLAN_SUMMARY="0 to destroy, only outputs left in state"
    elif ((changes == deletes)); then
      PLAN_SUMMARY="$deletes to destroy"
    else
      PLAN_SUMMARY="$deletes to destroy, $((changes - deletes)) other changes. Read the plan above."
    fi
    return 0
  fi

  text=$(strip_log <"$out" | grep -oE 'Plan: [0-9]+ to add.*|No changes\..*' | tail -n 1 || true)
  case "$text" in
    Plan:*) PLAN_SUMMARY="$text" ;;
    "No changes."*)
      PLAN_SUMMARY="$text"
      # Only trust it if the plan has no Plan: line anywhere.
      strip_log <"$out" | grep -qE 'Plan: [0-9]+ to add' || PLAN_GONE=1
      ;;
    *) PLAN_SUMMARY="could not read the plan, read it above. It will still be applied." ;;
  esac
}

# Drops color codes and carriage returns from terragrunt output.
strip_log() {
  sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//'
}

# A backend change (like a new state key) leaves old .terragrunt-cache dirs
# that terraform won't init over.
backend_hint() {
  strip_log <"$1" | grep -q 'Backend configuration changed' || return 0
  warn "The backend changed since these units were last run. Clear the local caches from the repo root, then run again:"
  warn "  find terraform -type d -name .terragrunt-cache -prune -exec rm -rf {} +"
}

# Destroy plan for one unit, saved for apply. Adds the plan's summary to
# SUMMARIES, and the unit to APPLY unless there's nothing to destroy.
plan_unit() {
  local env="$1" unit="$2" plan out
  plan=$(plan_file "$env" "$unit")
  CLEANUP+=("$plan")
  out=$(mktemp)
  CLEANUP+=("$out")

  info "[$env/$unit] destroy plan"
  terragrunt run --tf-forward-stdout \
    --working-dir "$(native_path "$(env_dir "$env")/$unit")" -- \
    plan -destroy -input=false -out="$(native_path "$plan")" | tee "$out" || {
    backend_hint "$out"
    die "[$env/$unit] destroy plan failed. Nothing was destroyed."
  }

  read_plan "$env" "$unit" "$plan" "$out"
  SUMMARIES+=("  $env/$unit: $PLAN_SUMMARY")
  if ((PLAN_GONE)); then
    rm -f "$plan"
  else
    APPLY+=("$env/$unit")
  fi
}

apply_unit() {
  local env="$1" unit="$2" plan
  plan=$(plan_file "$env" "$unit")
  session_check "$env/$unit"
  info "[$env/$unit] destroy"
  terragrunt run --tf-forward-stdout \
    --working-dir "$(native_path "$(env_dir "$env")/$unit")" -- \
    apply -input=false "$(native_path "$plan")" ||
    die "[$env/$unit] destroy failed. Units before it are gone and nothing after it ran. Fix the error above and run teardown.sh $TARGET again. Finished units plan as No changes and are skipped."
  rm -f "$plan"
}

# One leftover check. $1 label, $2 env, rest is the aws command. Prints
# what's left and returns 1, or returns 0 if nothing is.
check_one() {
  local label="$1" env="$2" out
  shift 2
  if ! out=$("$@" 2>&1); then
    printf '  %-14s could not check: %s\n' "$label" "$out"
    return 1
  fi
  out=$(tr -s '[:space:]' ' ' <<<"$out" | sed 's/^ //; s/ $//')
  if [[ -z "$out" || "$out" == None ]]; then
    printf '  %-14s none\n' "$label"
    return 0
  fi
  printf '  %-14s LEFT: %s\n' "$label" "$out"
  return 1
}

# The six things that cost money or block a rebuild if a destroy misses them.
leftover_checks() {
  local env="$1" region="$2" project="$3" prefix="$3-$1" bad=0
  local tags=("Name=tag:Project,Values=$project" "Name=tag:Environment,Values=$env")
  info "[$env] leftover checks in $region"
  check_one RDS "$env" aws rds describe-db-clusters --region "$region" \
    --query "DBClusters[?DBClusterIdentifier=='$prefix-aurora'].DBClusterIdentifier" --output text || bad=1
  check_one ALB "$env" aws elbv2 describe-load-balancers --region "$region" \
    --query "LoadBalancers[?LoadBalancerName=='$prefix-alb'].LoadBalancerName" --output text || bad=1
  check_one ECS "$env" aws ecs describe-clusters --region "$region" --clusters "$prefix-cluster" \
    --query "clusters[?status!='INACTIVE'].clusterName" --output text || bad=1
  check_one "VPC endpoints" "$env" aws ec2 describe-vpc-endpoints --region "$region" --filters "${tags[@]}" \
    --query "VpcEndpoints[?State!='deleted' && State!='Deleted'].VpcEndpointId" --output text || bad=1
  check_one VPC "$env" aws ec2 describe-vpcs --region "$region" --filters "${tags[@]}" \
    --query "Vpcs[].VpcId" --output text || bad=1
  check_one WAF "$env" aws wafv2 list-web-acls --region "$region" --scope REGIONAL \
    --query "WebACLs[?Name=='$prefix-alb'].Name" --output text || bad=1
  return "$bad"
}

# Tagged resource count for an env. Stops if the lookup fails, so an AWS
# error never reads as "nothing up".
env_count() {
  local list
  list=$(env_resources_left "$PROJECT" "$1" "$(env_region "$1")") ||
    die "Could not list tagged resources for $1."
  if [[ -z "$list" ]]; then echo 0; else grep -c . <<<"$list"; fi
}

# ---- backup jobs ----

# AWS Backup won't delete a vault while a backup or copy job is still
# writing to it, and the data destroy fails on it. A deploy that just
# rebuilt the stack often has one running. These find them, stop the
# backup jobs and wait for both kinds to finish. Restore jobs write to a
# new resource, not a vault, so they don't block it.
# States from ListBackupJobs and ListCopyJobs that are not final.
BACKUP_ACTIVE_STATES=(CREATED PENDING RUNNING ABORTING)
COPY_ACTIVE_STATES=(CREATED RUNNING)
BACKUP_WAIT_SECONDS="${MIGDEMO_BACKUP_WAIT_SECONDS:-1200}"
BACKUP_POLL_SECONDS="${MIGDEMO_BACKUP_POLL_SECONDS:-20}"

# "region vault" lines for every vault of this env: any vault named
# <project>-<env>-aurora*, listed live from AWS so a renamed or extra vault
# still shows up. The DR region only when the copy is on, since an SCP can
# block it. Stops if a lookup fails, so an AWS error never reads as "none".
backup_vaults() {
  local env="$1" prefix="$PROJECT-$1" region dr names r n
  region=$(env_region "$env")
  r="$region"
  if [[ "$(hcl_raw dr_copy_enabled "$(env_dir "$env")/env.hcl")" == true ]]; then
    dr=$(hcl_value dr_region "$(env_dir "$env")/env.hcl")
    [[ -n "$dr" ]] && r="$region $dr"
  fi
  for region in $r; do
    names=$(aws backup list-backup-vaults --region "$region" --output json |
      jq -r --arg p "$prefix-aurora" '.BackupVaultList[]? | select(.BackupVaultName | startswith($p)) | .BackupVaultName') ||
      die "[$env] could not list backup vaults in $region."
    [[ -z "$names" ]] || while read -r n; do printf '%s %s\n' "$region" "$n"; done <<<"$names"
  done
}

# Active jobs on the env's vaults, one "kind region id state vault" line
# each. kind is backup or copy.
active_backup_jobs() {
  local env="$1" vaults region vault st out
  vaults=$(backup_vaults "$env") || exit 1
  [[ -n "$vaults" ]] || return 0
  while read -r region vault; do
    for st in "${BACKUP_ACTIVE_STATES[@]}"; do
      out=$(aws backup list-backup-jobs --region "$region" --by-backup-vault-name "$vault" \
        --by-state "$st" --output json) || die "[$env] could not list backup jobs for $vault."
      jq -r --arg r "$region" '.BackupJobs[]? | "backup \($r) \(.BackupJobId) \(.State) \(.BackupVaultName)"' <<<"$out"
    done
    # Copy jobs can only be filtered by destination, so list the active
    # ones and match the vault on either end.
    for st in "${COPY_ACTIVE_STATES[@]}"; do
      out=$(aws backup list-copy-jobs --region "$region" --by-state "$st" --output json) ||
        die "[$env] could not list copy jobs in $region."
      jq -r --arg r "$region" --arg v "$vault" '.CopyJobs[]?
        | select((.SourceBackupVaultArn // "" | endswith(":backup-vault:" + $v))
              or (.DestinationBackupVaultArn // "" | endswith(":backup-vault:" + $v)))
        | "copy \($r) \(.CopyJobId) \(.State) \($v)"' <<<"$out"
    done
  done <<<"$vaults"
}

indent() {
  local l
  while IFS= read -r l; do printf '  %s\n' "$l"; done
}

# Prints the env's active jobs. 1 if there are any.
show_backup_jobs() {
  local env="$1" jobs
  jobs=$(active_backup_jobs "$env") || exit 1
  if [[ -z "$jobs" ]]; then
    info "[$env] no active backup or copy jobs"
    return 0
  fi
  info "[$env] active backup jobs (kind region id state vault):"
  indent <<<"$jobs"
  return 1
}

# Stops the env's backup jobs and waits until none are left, backup or
# copy. Copy jobs can't be stopped, only waited on. Only runs after the
# typed confirmation.
clear_backup_jobs() {
  local env="$1" jobs kind region id state vault waited=0
  session_check "$env backup jobs"
  show_backup_jobs "$env" && return 0
  jobs=$(active_backup_jobs "$env") || exit 1
  while read -r kind region id state vault; do
    [[ "$kind" == backup && "$state" != ABORTING ]] || continue
    info "[$env] stopping backup job $id on $vault"
    aws backup stop-backup-job --region "$region" --backup-job-id "$id" ||
      warn "[$env] could not stop backup job $id. Waiting for it to end."
  done <<<"$jobs"
  while :; do
    jobs=$(active_backup_jobs "$env") || exit 1
    [[ -n "$jobs" ]] || break
    if ((waited >= BACKUP_WAIT_SECONDS)); then
      indent <<<"$jobs" >&2
      die "[$env] backup jobs still active after ${BACKUP_WAIT_SECONDS}s (above). Nothing in data was destroyed. Check them in the AWS Backup console, then run teardown.sh $TARGET again."
    fi
    info "[$env] waiting on $(grep -c . <<<"$jobs") backup job(s), ${waited}s of ${BACKUP_WAIT_SECONDS}s"
    sleep "$BACKUP_POLL_SECONDS"
    waited=$((waited + BACKUP_POLL_SECONDS))
  done
  info "[$env] no active backup jobs left"
}

# ---- run ----

log_init "teardown-$TARGET"
((DRY_RUN)) && info "Dry run"

require_tools aws terraform terragrunt jq
if ((DRY_RUN)); then
  ensure_session
else
  # Fresh sign-in so the session lasts the whole run.
  session_refresh
fi
check_account
resolve_inputs
PROJECT=$(resolve_project)

# Preflight: what's up where.
RUN=()
info "Preflight"
printf '  %-11s %-13s %-10s %s\n' env account region "tagged resources"
for env in "${TARGETS[@]}"; do
  [[ -f "$(env_dir "$env")/env.hcl" ]] || die "No terraform/environments/$env/env.hcl"
  region=$(env_region "$env")
  n=$(env_count "$env")
  printf '  %-11s %-13s %-10s %s\n' "$env" "$ACCOUNT_ID" "$region" "$n"
  if ((n > 0)); then
    RUN+=("$env")
  else
    info "[$env] nothing tagged Project=$PROJECT Environment=$env, skipping."
  fi
done
info "State bucket: $TF_STATE_BUCKET (not touched)"

((${#RUN[@]} > 0)) || die "Nothing to tear down. Wrong account or region? Tags can also lag a few minutes after a teardown."

# A single env going away strands anything that promotes from it.
if [[ "$TARGET" != all ]]; then
  for down in $(downstream_of "$TARGET"); do
    n=$(env_count "$down")
    if ((n > 0)); then
      warn "$down is still up ($n tagged resources) and promotes from $TARGET. Tearing down $TARGET strands it: nothing can be promoted to $down until $TARGET is deployed again. Tear down $down first, or use all."
    fi
  done
fi

SUMMARIES=()
APPLY=()
for env in "${RUN[@]}"; do
  for unit in "${UNITS[@]}"; do
    session_check "$env/$unit plan"
    plan_unit "$env" "$unit"
  done
done

info "Summary"
printf '%s\n' "${SUMMARIES[@]}"

for env in "${RUN[@]}"; do
  # Listed only. A real run stops them right before the data unit.
  show_backup_jobs "$env" || ((DRY_RUN)) || info "[$env] these get stopped before data is destroyed."
done

if ((DRY_RUN)); then
  info "Dry run: nothing destroyed."
  exit 0
fi

confirm "$TARGET" "destroy everything planned above in: ${RUN[*]}"

for env in "${RUN[@]}"; do
  for unit in "${UNITS[@]}"; do
    if [[ " ${APPLY[*]-} " == *" $env/$unit "* ]]; then
      # Checked here, not up front, so a job that starts while app goes
      # down is still caught.
      [[ "$unit" != data ]] || clear_backup_jobs "$env"
      apply_unit "$env" "$unit"
    else
      info "[$env/$unit] nothing to destroy"
    fi
  done
  session_check "$env leftover checks"
  leftover_checks "$env" "$(env_region "$env")" "$PROJECT" ||
    die "[$env] something is still up (above). Fix it before tearing down anything else."
  info "[$env] torn down."
done

info "Done. Bootstrap and the state bucket are still in place."
