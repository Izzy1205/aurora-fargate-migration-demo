#!/usr/bin/env bash
# Applies terraform/bootstrap (CI roles) per environment and the state bucket
# root, then sets the role ARNs on the GitHub environments. Run from a
# machine with admin creds, never from CI. See --help.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

BOOT_DIR="$REPO_ROOT/terraform/bootstrap"
SB_DIR="$REPO_ROOT/terraform/state-bucket"
DEFAULT_KEY_PREFIX="aurora-fargate-migration-demo"
SB_KEY="$DEFAULT_KEY_PREFIX/bootstrap-state-bucket.tfstate"
ENVS=(testing stage production)

usage() {
  cat <<'USAGE'
Usage:
  scripts/bootstrap.sh <testing|stage|production|all> [--no-github] [--dry-run]
  scripts/bootstrap.sh destroy <testing|stage|production> [--dry-run]
  scripts/bootstrap.sh state-bucket [--dry-run]

  testing|stage|production  Plan and apply terraform/bootstrap for that env,
                            then set its role ARNs on the GitHub environments.
  all                       testing, then stage, then production. Stops at the
                            first failure.
  destroy <env>             Destroy that env's bootstrap. Refuses while the env
                            still has tagged resources, and refuses testing
                            while stage or production still has a bootstrap.
  state-bucket              Plan and apply terraform/state-bucket. The first
                            run adopts an existing bucket or creates one, then
                            moves the state into the bucket.

Options:
  --no-github   Don't write GitHub variables. Print the gh commands instead.
  --dry-run     Init and plan only. No apply, no GitHub writes.
  -h, --help    Show this help.

Before you run it:
  - Sign in to AWS (aws login). The script signs in if there's no session.
  - The account comes from aws sts get-caller-identity and is shown in
    the preflight. To pin it, set MIGDEMO_ACCOUNT_ID or expected_account_id
    in terraform/state-bucket/terraform.tfvars. A pinned run stops on any
    other account.
  - Copy each *.tfvars.example to its tfvars and replace every REPLACE-ME.
      testing:    terraform/bootstrap/terraform.tfvars
      stage:      terraform/bootstrap/stage.tfvars
      production: terraform/bootstrap/production.tfvars
    state-bucket writes terraform/state-bucket/terraform.tfvars for you if
    it's missing, from the testing tfvars and the signed in account.
  - gh auth login, for the GitHub step.

Every run is logged to logs/<timestamp>-<command>.log (gitignored).
USAGE
}

# ---- args ----

TARGET=""
DESTROY_ENV=""
NO_GITHUB=0
DRY_RUN=0

while (($#)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --no-github) NO_GITHUB=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*)
      usage >&2
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      elif [[ "$TARGET" == destroy && -z "$DESTROY_ENV" ]]; then
        DESTROY_ENV="$1"
      else
        usage >&2
        die "Unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

is_env() { [[ "$1" == testing || "$1" == stage || "$1" == production ]]; }

case "$TARGET" in
  testing | stage | production | all | state-bucket) ;;
  destroy)
    is_env "$DESTROY_ENV" || {
      usage >&2
      die "destroy needs testing, stage or production."
    }
    ;;
  "")
    usage >&2
    exit 2
    ;;
  *)
    usage >&2
    die "Unknown command: $TARGET"
    ;;
esac

# ---- helpers ----

# Saved plans and the temp backend override are removed on any exit, so a
# stopped run never leaves a stale plan behind.
CLEANUP=()
cleanup() {
  local f
  for f in ${CLEANUP[@]+"${CLEANUP[@]}"}; do rm -f "$f"; done
}
trap cleanup EXIT

env_tfvars() {
  case "$1" in
    testing) echo terraform.tfvars ;;
    *) echo "$1.tfvars" ;;
  esac
}

# Value of a bootstrap variable the way terraform resolves it here:
# the env's tfvars, then terraform.tfvars (always auto-loaded), then $3.
tfvar() {
  local env="$1" name="$2" fallback="${3:-}" v=""
  v=$(hcl_value "$name" "$BOOT_DIR/$(env_tfvars "$env")")
  if [[ -z "$v" && "$env" != testing && -f "$BOOT_DIR/terraform.tfvars" ]]; then
    v=$(hcl_value "$name" "$BOOT_DIR/terraform.tfvars")
  fi
  printf '%s\n' "${v:-$fallback}"
}

env_state_key() {
  local prefix
  prefix=$(tfvar "$1" state_key_prefix "$DEFAULT_KEY_PREFIX")
  case "$1" in
    testing) echo "$prefix/bootstrap.tfstate" ;;
    *) echo "$prefix/bootstrap-$1.tfstate" ;;
  esac
}

# terraform in a root dir, with its own data dir per env so each env keeps
# its own backend init and saved plans stay valid. TF_DATA_DIR must be the
# same for every command from init on:
# https://developer.hashicorp.com/terraform/cli/config/environment-variables#tf_data_dir
tf_in() {
  local dir="$1" data="$2"
  shift 2
  (cd "$dir" && TF_DATA_DIR="$data" terraform "$@")
}

oidc_provider_exists() {
  local arns
  arns=$(aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?ends_with(Arn, '/token.actions.githubusercontent.com')].Arn" \
    --output text)
  [[ -n "$arns" && "$arns" != None ]]
}

bucket_exists() {
  aws s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

object_exists() {
  aws s3api head-object --bucket "$1" --key "$2" --region "$3" >/dev/null 2>&1
}

check_tfvars_file() {
  local f="$1" hits
  [[ -f "$f" ]] || die "Missing ${f#"$REPO_ROOT"/}. Copy it from ${f#"$REPO_ROOT"/}.example and fill it in."
  hits=$(replace_me_lines "$f")
  [[ -z "$hits" ]] || die "${f#"$REPO_ROOT"/} still has REPLACE-ME values:
$hits"
}

# Counts and changed addresses of a saved plan. Sets PLAN_DELETES.
summarize_plan() {
  local dir="$1" data="$2" plan="$3" json
  json=$(tf_in "$dir" "$data" show -json "$plan")
  jq -r '
    [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $c
    | "  \($c | map(select(.change.actions == ["create"])) | length) to add, "
      + "\($c | map(select(.change.actions == ["update"])) | length) to change, "
      + "\($c | map(select(.change.actions | index("delete"))) | length) to destroy or replace, "
      + "\([.resource_changes[]? | select(.change.importing != null)] | length) to import",
      ($c[] | "    \(.change.actions | join("/"))  \(.address)")
  ' <<<"$json"
  PLAN_DELETES=$(jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' <<<"$json")
  PLAN_CHANGES=$(jq '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length' <<<"$json")
}

preflight_common() {
  local tools=(aws terraform jq)
  ((NO_GITHUB)) || tools+=(gh)
  require_tools "${tools[@]}"
  ensure_session
  check_account
  if ((!NO_GITHUB)); then
    gh auth status >/dev/null 2>&1 || die "gh is not signed in. Run gh auth login, or use --no-github."
  fi
}

preflight_env() {
  local env="$1" f got bucket oidc
  f="$BOOT_DIR/$(env_tfvars "$env")"
  check_tfvars_file "$f"
  # terraform.tfvars loads for every env, so its placeholders count too.
  [[ "$env" == testing ]] || check_tfvars_file "$BOOT_DIR/terraform.tfvars"

  got=$(hcl_value environment "$f")
  [[ "${got:-testing}" == "$env" ]] ||
    die "${f#"$REPO_ROOT"/} sets environment = \"$got\", expected \"$env\"."

  oidc=$(hcl_raw create_github_oidc_provider "$f")
  if [[ "$env" != testing && "$oidc" != false ]]; then
    die "${f#"$REPO_ROOT"/} must set create_github_oidc_provider = false. Testing's bootstrap owns the provider."
  fi

  bucket=$(tfvar "$env" state_bucket_name)
  [[ -n "$bucket" ]] || die "state_bucket_name is not set for $env."
  bucket_exists "$bucket" || die "State bucket $bucket not found. Run scripts/bootstrap.sh state-bucket first."
}

plan_env() {
  local env="$1" bucket key region data plan
  bucket=$(tfvar "$env" state_bucket_name)
  key=$(env_state_key "$env")
  region="${TF_STATE_REGION:-$(tfvar "$env" aws_region us-east-2)}"
  data=".terraform-$env"
  plan="bootstrap-$env.tfplan"
  CLEANUP+=("$BOOT_DIR/$plan")

  info "[$env] init (s3://$bucket/$key, $region)"
  tf_in "$BOOT_DIR" "$data" init -reconfigure -input=false \
    -backend-config="bucket=$bucket" \
    -backend-config="key=$key" \
    -backend-config="region=$region"

  info "[$env] plan"
  local args=(plan -input=false -out="$plan")
  [[ "$env" == testing ]] || args+=(-var-file="$(env_tfvars "$env")")
  tf_in "$BOOT_DIR" "$data" "${args[@]}"

  info "[$env] summary"
  summarize_plan "$BOOT_DIR" "$data" "$plan"
  if ((PLAN_DELETES > 0)); then
    warn "[$env] this plan destroys or replaces $PLAN_DELETES resource(s). Read the list above before you confirm."
  fi
  printf -v "PLANNED_${env}" %s "$PLAN_CHANGES"
}

apply_env() {
  local env="$1" data=".terraform-$1" plan="bootstrap-$1.tfplan" planned="PLANNED_$1"
  if [[ "${!planned:-1}" == 0 ]]; then
    info "[$env] no changes to apply"
  else
    info "[$env] apply"
    tf_in "$BOOT_DIR" "$data" apply -input=false "$plan"
  fi
  rm -f "$BOOT_DIR/$plan"
}

# Sets the role ARNs from terraform output on the env's three GitHub
# environments, then reads them back.
github_sync() {
  local env="$1" data=".terraform-$1" repo outputs gh_env name output value now
  repo=$(tfvar "$env" github_repo)
  outputs=$(tf_in "$BOOT_DIR" "$data" output -json)

  local -a gh_envs=(
    "$(tfvar "$env" github_plan_environment "$env-infra-plan")"
    "$(tfvar "$env" github_infra_environment "$env-infra")"
    "$(tfvar "$env" github_app_environment "$env-app")"
  )
  local -a pairs=(
    AWS_PLAN_ROLE_ARN:plan_role_arn
    AWS_TERRAFORM_ROLE_ARN:terraform_role_arn
    AWS_DEPLOY_ROLE_ARN:deploy_role_arn
  )

  info "[$env] GitHub variables on $repo"
  for gh_env in "${gh_envs[@]}"; do
    for pair in "${pairs[@]}"; do
      name="${pair%%:*}"
      output="${pair#*:}"
      value=$(jq -r --arg o "$output" '.[$o].value // empty' <<<"$outputs")
      if [[ -z "$value" ]]; then
        warn "[$env] no $output output yet (nothing applied?), skipping $name on $gh_env"
        continue
      fi
      if ((NO_GITHUB)); then
        printf '  gh variable set %s --env %s --body %s --repo %s\n' "$name" "$gh_env" "$value" "$repo"
      elif ((DRY_RUN)); then
        now=$(gh variable get "$name" --env "$gh_env" --repo "$repo" 2>/dev/null || echo "<unset>")
        if [[ "$now" == "$value" ]]; then
          printf '  %s/%s already %s\n' "$gh_env" "$name" "$value"
        else
          printf '  %s/%s would change: %s -> %s\n' "$gh_env" "$name" "$now" "$value"
        fi
      else
        gh variable set "$name" --env "$gh_env" --body "$value" --repo "$repo" >/dev/null ||
          die "gh variable set $name on $gh_env failed. Does the $gh_env environment exist on $repo?"
        now=$(gh variable get "$name" --env "$gh_env" --repo "$repo")
        [[ "$now" == "$value" ]] || die "$gh_env/$name reads back as $now, expected $value."
        printf '  %s/%s = %s (checked)\n' "$gh_env" "$name" "$value"
      fi
    done
  done
}

run_envs() {
  local word="$1"
  shift
  local env
  for env in "$@"; do preflight_env "$env"; done
  for env in "$@"; do plan_env "$env"; done

  if ((DRY_RUN)); then
    info "Dry run: nothing applied."
    for env in "$@"; do github_sync "$env"; done
    return 0
  fi

  confirm "$word" "apply the plan(s) above for: $*"
  for env in "$@"; do
    apply_env "$env"
    github_sync "$env"
  done
}

cmd_bootstrap() {
  preflight_common
  case "$TARGET" in
    all)
      if oidc_provider_exists; then
        run_envs all "${ENVS[@]}"
      else
        # Stage and production read the provider testing creates, so they
        # can't be planned until testing is applied.
        info "No GitHub OIDC provider yet. Testing goes first, then stage and production."
        run_envs testing testing
        if ((DRY_RUN)); then
          warn "Dry run: stage and production can't be planned until testing is applied."
          return 0
        fi
        run_envs all stage production
      fi
      ;;
    testing)
      run_envs testing testing
      ;;
    *)
      oidc_provider_exists || die "No GitHub OIDC provider in this account. Run scripts/bootstrap.sh testing first."
      run_envs "$TARGET" "$TARGET"
      ;;
  esac
  info "Done."
}

role_exists() {
  aws iam get-role --role-name "$1" >/dev/null 2>&1
}

cmd_destroy() {
  local env="$DESTROY_ENV" project region left other data plan bucket key
  NO_GITHUB=1
  preflight_common
  preflight_env "$env"
  project=$(tfvar "$env" project "$(resolve_project)")
  region=$(tfvar "$env" aws_region us-east-2)

  left=$(env_resources_left "$project" "$env" "$region")
  if [[ -n "$left" ]]; then
    printf '%s\n' "$left" | sed 's/^/  /'
    die "$env still has tagged resources (above). Run scripts/teardown.sh $env first. Tags can lag a few minutes after a teardown."
  fi

  if [[ "$env" == testing ]]; then
    for other in stage production; do
      if role_exists "$project-$other-github-plan"; then
        die "The $other bootstrap still exists and uses testing's OIDC provider. Destroy $other first."
      fi
    done
  fi

  bucket=$(tfvar "$env" state_bucket_name)
  key=$(env_state_key "$env")
  data=".terraform-$env"
  plan="bootstrap-$env-destroy.tfplan"
  CLEANUP+=("$BOOT_DIR/$plan")

  info "[$env] init (s3://$bucket/$key)"
  tf_in "$BOOT_DIR" "$data" init -reconfigure -input=false \
    -backend-config="bucket=$bucket" \
    -backend-config="key=$key" \
    -backend-config="region=${TF_STATE_REGION:-$region}"

  local args=(plan -destroy -input=false -out="$plan")
  [[ "$env" == testing ]] || args+=(-var-file="$(env_tfvars "$env")")
  info "[$env] destroy plan"
  tf_in "$BOOT_DIR" "$data" "${args[@]}"
  summarize_plan "$BOOT_DIR" "$data" "$plan"

  if ((DRY_RUN)); then
    rm -f "$BOOT_DIR/$plan"
    info "Dry run: nothing destroyed."
    return 0
  fi

  confirm "$env" "destroy the $env bootstrap (CI roles and boundaries)"
  tf_in "$BOOT_DIR" "$data" apply -input=false "$plan"
  rm -f "$BOOT_DIR/$plan"
  info "[$env] bootstrap destroyed. Its GitHub environment variables are left in place and now point at deleted roles."
}

# Suggested state bucket name: TF_STATE_BUCKET, then state_bucket_name in
# the testing tfvars, then <owner>-<project>-tfstate-<year>.
suggest_bucket() {
  local owner="$1" name="${TF_STATE_BUCKET:-}"
  if [[ -z "$name" && -f "$BOOT_TFVARS" ]]; then
    name=$(hcl_value state_bucket_name "$BOOT_TFVARS")
  fi
  [[ "$name" == *REPLACE-ME* ]] && name=""
  [[ -n "$name" ]] || name="$owner-$(resolve_project)-tfstate-$(date +%Y)"
  printf '%s\n' "$name" | tr '[:upper:]' '[:lower:]'
}

# Writes terraform/state-bucket/terraform.tfvars after one confirmation.
# The account goes in as the pin, so later runs stop on any other account.
write_state_bucket_tfvars() {
  local f="$1" owner region bucket
  owner=$(resolve_owner "")
  [[ -n "$owner" ]] || die "No owner to put in ${f#"$REPO_ROOT"/}. Fill in owner in terraform/bootstrap/terraform.tfvars or set MIGDEMO_OWNER."
  region=$(resolve_region)
  bucket=$(suggest_bucket "$owner")

  info "${f#"$REPO_ROOT"/} is missing. This is what would go in it:"
  local body
  body=$(
    cat <<EOF
# Written by scripts/bootstrap.sh state-bucket. Gitignored.
# See terraform.tfvars.example for the other settings.
owner               = "$owner"
expected_account_id = "$ACCOUNT_ID"
bucket_name         = "$bucket"
aws_region          = "$region"
EOF
  )
  printf '%s\n' "$body" | sed 's/^/  /'
  info "Bucket names are global and can't be renamed. To pick another one, type anything else and copy terraform.tfvars.example by hand."
  confirm yes "write it and go on"
  printf '%s\n' "$body" >"$f"
  info "Wrote ${f#"$REPO_ROOT"/}"
}

cmd_state_bucket() {
  local f="$SB_DIR/terraform.tfvars" bucket region owner import=false mode data=".terraform" plan="state-bucket.tfplan"
  NO_GITHUB=1
  preflight_common
  [[ -f "$f" ]] || write_state_bucket_tfvars "$f"
  check_tfvars_file "$f"
  bucket=$(hcl_value bucket_name "$f")
  region=$(resolve_region "$f")
  [[ -n "$bucket" ]] || die "bucket_name is not set in ${f#"$REPO_ROOT"/}."

  # Owner and region default from the testing tfvars when this file
  # doesn't set them, so the same values aren't typed twice.
  local var_args=()
  if [[ -z "$(hcl_value owner "$f")" ]]; then
    owner=$(resolve_owner "")
    [[ -n "$owner" ]] || die "Set owner in ${f#"$REPO_ROOT"/} or terraform/bootstrap/terraform.tfvars."
    var_args+=(-var="owner=$owner")
  fi
  [[ -n "$(hcl_value aws_region "$f")" ]] || var_args+=(-var="aws_region=$region")

  local backend_args=(
    -backend-config="bucket=$bucket"
    -backend-config="key=$SB_KEY"
    -backend-config="region=$region"
  )
  local override="$SB_DIR/backend_override.tf"
  CLEANUP+=("$SB_DIR/$plan" "$override")

  if bucket_exists "$bucket" && object_exists "$bucket" "$SB_KEY" "$region"; then
    mode=remote
    info "State found at s3://$bucket/$SB_KEY"
    rm -f "$override"
    tf_in "$SB_DIR" "$data" init -reconfigure -input=false "${backend_args[@]}"
  else
    mode=local
    if bucket_exists "$bucket"; then
      import=true
      info "Bucket $bucket exists with no state for it yet. It will be imported."
    else
      info "Bucket $bucket does not exist. It will be created."
    fi
    # First run: local state, moved into the bucket after apply. A backend
    # block in an override file replaces the one in backend.tf:
    # https://developer.hashicorp.com/terraform/language/files/override
    # backend_override.tf is gitignored (*_override.tf).
    printf '# Written by scripts/bootstrap.sh for the first apply. Removed after.\nterraform {\n  backend "local" {}\n}\n' >"$override"
    tf_in "$SB_DIR" "$data" init -reconfigure -input=false
  fi

  info "[state-bucket] plan"
  tf_in "$SB_DIR" "$data" plan -input=false -var="import_existing_bucket=$import" ${var_args[@]+"${var_args[@]}"} -out="$plan"
  summarize_plan "$SB_DIR" "$data" "$plan"
  if ((PLAN_DELETES > 0)); then
    warn "This plan destroys or replaces $PLAN_DELETES resource(s). Read the list above before you confirm."
  fi

  if ((DRY_RUN)); then
    rm -f "$SB_DIR/$plan"
    info "Dry run: nothing applied."
    return 0
  fi

  confirm state-bucket "apply the state bucket plan above"
  tf_in "$SB_DIR" "$data" apply -input=false "$plan"
  rm -f "$SB_DIR/$plan"

  if [[ "$mode" == local ]]; then
    # -force-copy answers yes to the copy prompt and implies -migrate-state:
    # https://developer.hashicorp.com/terraform/cli/commands/init#backend-initialization
    info "[state-bucket] moving state into s3://$bucket/$SB_KEY"
    rm -f "$override"
    tf_in "$SB_DIR" "$data" init -migrate-state -force-copy -input=false "${backend_args[@]}"
    object_exists "$bucket" "$SB_KEY" "$region" || die "State is not in the bucket after the move. Local state is still in terraform/state-bucket/terraform.tfstate."
    if [[ -f "$SB_DIR/terraform.tfstate" ]]; then
      mv "$SB_DIR/terraform.tfstate" "$SB_DIR/terraform.tfstate.migrated-$(date +%Y%m%d-%H%M%S)"
      info "Old local state kept as terraform/state-bucket/terraform.tfstate.migrated-* (gitignored). Delete it once you're happy."
    fi
  fi
  info "Done. Bucket: $bucket ($region)"
}

log_init "bootstrap-${TARGET}${DESTROY_ENV:+-$DESTROY_ENV}"
((DRY_RUN)) && info "Dry run"

case "$TARGET" in
  destroy) cmd_destroy ;;
  state-bucket) cmd_state_bucket ;;
  *) cmd_bootstrap ;;
esac
