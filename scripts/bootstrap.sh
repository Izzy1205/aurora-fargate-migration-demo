#!/usr/bin/env bash
# Applies terraform/bootstrap (CI roles) per environment and the state bucket
# root, then sets the role ARNs on the GitHub environments. Run from a
# machine with admin creds, never from CI. See --help.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

BOOT_DIR="$REPO_ROOT/terraform/bootstrap"
SB_DIR="$REPO_ROOT/terraform/state-bucket"
ORG_DIR="$REPO_ROOT/terraform/org"
LEGACY_TFVARS="$BOOT_DIR/terraform.tfvars"
DEFAULT_KEY_PREFIX="aurora-fargate-migration-demo"
SB_KEY="$DEFAULT_KEY_PREFIX/bootstrap-state-bucket.tfstate"
ENVS=(testing stage production)

usage() {
  cat <<'USAGE'
Usage:
  scripts/bootstrap.sh <testing|stage|production|all> [--no-github] [--dry-run]
  scripts/bootstrap.sh destroy <testing|stage|production> [--dry-run]
  scripts/bootstrap.sh state-bucket [testing|stage|production] [--dry-run]
  scripts/bootstrap.sh org [--dry-run]

  testing|stage|production  Plan and apply terraform/bootstrap for that env,
                            then set its role ARNs on the GitHub environments.
  all                       testing, then stage, then production. Stops at the
                            first failure.
  destroy <env>             Destroy that env's bootstrap. Refuses while the env
                            still has tagged resources, and refuses testing
                            while stage or production still has a bootstrap.
  state-bucket              Plan and apply terraform/state-bucket. The first
                            run adopts an existing bucket or creates one, then
                            moves the state into the bucket. With an env
                            that has its own account, it works on that
                            account's bucket from state-bucket/<env>.tfvars.
  org                       Plan and apply terraform/org (the demo OU and its
                            SCPs) from the management account, then move the
                            accounts in ou_account_ids into the OU, one
                            confirm each. Stops unless the signed in account
                            is management_account_id in
                            terraform/org/terraform.tfvars.

Options:
  --no-github   Don't write GitHub variables. Print the gh commands instead.
  --dry-run     Init and plan only. No apply, no GitHub writes.
  -h, --help    Show this help.

Before you run it:
  - Sign in to AWS (aws login). The script signs in if there's no session.
  - Each env's account comes from terraform/accounts.hcl (copy
    accounts.hcl.example), then MIGDEMO_<ENV>_ACCOUNT_ID, then the single
    pin MIGDEMO_ACCOUNT_ID or expected_account_id in
    terraform/state-bucket/terraform.tfvars. A run stops when the signed in
    account isn't the env's account, and says which profile to use.
  - <env>_aws_profile in accounts.hcl (or MIGDEMO_<ENV>_AWS_PROFILE) makes
    the script switch AWS_PROFILE per env. all needs one for every env when
    the envs are in more than one account, and stops otherwise.
  - Copy each *.tfvars.example to its tfvars and replace every REPLACE-ME.
      testing:    terraform/bootstrap/testing.tfvars
      stage:      terraform/bootstrap/stage.tfvars
      production: terraform/bootstrap/production.tfvars
    state-bucket writes terraform/state-bucket/terraform.tfvars for you if
    it's missing, from the testing tfvars and the signed in account.
  - testing.tfvars used to be terraform/bootstrap/terraform.tfvars. If the
    old name is still there, the script offers to rename it once.
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
      elif [[ "$TARGET" == destroy || "$TARGET" == state-bucket ]] && [[ -z "$DESTROY_ENV" ]]; then
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
  testing | stage | production | all | org) ;;
  state-bucket)
    [[ -z "$DESTROY_ENV" ]] || is_env "$DESTROY_ENV" || {
      usage >&2
      die "state-bucket takes testing, stage or production."
    }
    ;;
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

# Every env passes its own file with -var-file. Nothing in terraform/bootstrap
# may be named terraform.tfvars, since terraform loads that name on its own
# for every env.
env_tfvars() { echo "$1.tfvars"; }

# Value of a bootstrap variable the way terraform resolves it here:
# the env's tfvars, then $3.
tfvar() {
  local env="$1" name="$2" fallback="${3:-}" v=""
  v=$(hcl_value "$name" "$BOOT_DIR/$(env_tfvars "$env")")
  printf '%s\n' "${v:-$fallback}"
}

# Testing's tfvars used to be terraform.tfvars. Terraform loads that name on
# its own, so it also loaded under stage and production and filled in
# anything their files didn't set. Rename it once, after a confirm.
migrate_legacy_tfvars() {
  [[ -f "$LEGACY_TFVARS" ]] || return 0
  local old="${LEGACY_TFVARS#"$REPO_ROOT"/}" new="terraform/bootstrap/testing.tfvars"
  if [[ -f "$REPO_ROOT/$new" ]]; then
    die "Both $old and $new exist. Terraform would load $old for every env. Move anything you still need into $new, then delete $old."
  fi
  warn "$old is testing's old tfvars name. Terraform loads it for every env, so it's $new now."
  info "Or do it by hand: mv $old $new"
  confirm yes "rename it to $new"
  mv "$LEGACY_TFVARS" "$REPO_ROOT/$new"
  BOOT_TFVARS="$REPO_ROOT/$new"
  info "Renamed $old to $new"
}

# Stage and production used to pick up any value testing's file set and
# theirs didn't. Stop if one of those would now fall back to the default,
# so no env's values change without you seeing it.
check_inherited() {
  local env="$1" f="$BOOT_DIR/$1.tfvars" t="$BOOT_DIR/testing.tfvars" missing
  [[ "$env" != testing && -f "$t" ]] || return 0
  missing=$(comm -23 <(tfvars_names "$t" | sort -u) <(tfvars_names "$f" | sort -u))
  [[ -z "$missing" ]] || die "${t#"$REPO_ROOT"/} sets these and ${f#"$REPO_ROOT"/} doesn't:
$(printf '%s\n' "$missing" | sed 's/^/  /')
$env used to get testing's value for them. Add each one to ${f#"$REPO_ROOT"/}, with testing's value to keep the plan the same."
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

# Envs in the same account as testing share its GitHub OIDC provider.
# With no accounts set they all match, same as before the account map.
shares_testing_account() {
  [[ "$(env_account "$1")" == "$(env_account testing)" ]]
}

# Switches to an env's profile and checks its account, once per change.
switch_env() {
  [[ "${CUR_ENV:-}" == "$1" ]] && return 0
  use_env "$1"
  CUR_ENV="$1"
}

preflight_common() {
  local tools=(aws terraform jq)
  ((NO_GITHUB)) || tools+=(gh)
  require_tools "${tools[@]}"
  if ((!NO_GITHUB)); then
    gh auth status >/dev/null 2>&1 || die "gh is not signed in. Run gh auth login, or use --no-github."
  fi
}

preflight_env() {
  local env="$1" f got bucket oidc
  switch_env "$env"
  f="$BOOT_DIR/$(env_tfvars "$env")"
  check_tfvars_file "$f"
  check_inherited "$env"

  got=$(hcl_value environment "$f")
  [[ "${got:-testing}" == "$env" ]] ||
    die "${f#"$REPO_ROOT"/} sets environment = \"$got\", expected \"$env\"."

  oidc=$(hcl_raw create_github_oidc_provider "$f")
  if [[ "$env" != testing ]]; then
    if shares_testing_account "$env"; then
      [[ "$oidc" == false ]] ||
        die "${f#"$REPO_ROOT"/} must set create_github_oidc_provider = false. $env is in testing's account and testing's bootstrap owns the provider."
    else
      [[ "$oidc" != false ]] ||
        die "${f#"$REPO_ROOT"/} sets create_github_oidc_provider = false, but $env has its own account, which needs its own provider. Set it to true."
    fi
  fi

  bucket=$(tfvar "$env" state_bucket_name)
  [[ -n "$bucket" ]] || die "state_bucket_name is not set for $env."
  bucket_exists "$bucket" || die "State bucket $bucket not found. Run scripts/bootstrap.sh state-bucket first."
}

# Sets KMS_ARGS to the -backend-config for the state key, or to nothing
# when there's no key.
kms_backend_args() {
  local kms
  kms=$(state_kms_key)
  KMS_ARGS=()
  [[ -z "$kms" ]] || KMS_ARGS=(-backend-config="kms_key_id=$kms")
}

plan_env() {
  local env="$1" bucket key region data plan
  switch_env "$env"
  bucket=$(tfvar "$env" state_bucket_name)
  key=$(env_state_key "$env")
  region="${TF_STATE_REGION:-$(tfvar "$env" aws_region us-east-2)}"
  data=".terraform-$env"
  plan="bootstrap-$env.tfplan"
  CLEANUP+=("$BOOT_DIR/$plan")

  kms_backend_args
  info "[$env] init (s3://$bucket/$key, $region)"
  tf_in "$BOOT_DIR" "$data" init -reconfigure -input=false \
    -backend-config="bucket=$bucket" \
    -backend-config="key=$key" \
    -backend-config="region=$region" \
    ${KMS_ARGS[@]+"${KMS_ARGS[@]}"}

  info "[$env] plan"
  local args=(plan -input=false -out="$plan" -var-file="$(env_tfvars "$env")")
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
  switch_env "$env"
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
  switch_env "$env"
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

# True when some env other than testing reads testing's OIDC provider.
any_shares_testing() {
  local e
  for e in stage production; do
    shares_testing_account "$e" && return 0
  done
  return 1
}

cmd_bootstrap() {
  preflight_common
  migrate_legacy_tfvars
  case "$TARGET" in
    all)
      check_multi_account "${ENVS[@]}"
      switch_env testing
      if ! any_shares_testing || oidc_provider_exists; then
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
      if shares_testing_account "$TARGET"; then
        switch_env "$TARGET"
        oidc_provider_exists || die "No GitHub OIDC provider in this account. Run scripts/bootstrap.sh testing first."
      fi
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
  migrate_legacy_tfvars
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
      shares_testing_account "$other" || continue
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

  kms_backend_args
  info "[$env] init (s3://$bucket/$key)"
  tf_in "$BOOT_DIR" "$data" init -reconfigure -input=false \
    -backend-config="bucket=$bucket" \
    -backend-config="key=$key" \
    -backend-config="region=${TF_STATE_REGION:-$region}" \
    ${KMS_ARGS[@]+"${KMS_ARGS[@]}"}

  local args=(plan -destroy -input=false -out="$plan" -var-file="$(env_tfvars "$env")")
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
  [[ -n "$owner" ]] || die "No owner to put in ${f#"$REPO_ROOT"/}. Fill in owner in terraform/bootstrap/testing.tfvars or set MIGDEMO_OWNER."
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

# state-bucket [env]. With no env, or one in testing's account, this is
# the one bucket in terraform/state-bucket/terraform.tfvars, same as before
# the account map. An env with its own account gets its own bucket and key
# from state-bucket/<env>.tfvars, with its own local data dir. Its state
# key in its own bucket has the same name, since buckets don't overlap.
cmd_state_bucket() {
  local env="${DESTROY_ENV:-testing}"
  local f="$SB_DIR/terraform.tfvars" bucket region owner import=false mode data=".terraform" plan="state-bucket.tfplan"
  local file_args=()
  NO_GITHUB=1
  preflight_common
  if [[ "$env" != testing ]] && ! shares_testing_account "$env"; then
    f="$SB_DIR/$env.tfvars"
    data=".terraform-$env"
    plan="state-bucket-$env.tfplan"
    file_args=(-var-file="$env.tfvars")
    SB_TFVARS="$f"
    [[ -f "$f" ]] || die "$env has its own account. Copy terraform/state-bucket/terraform.tfvars.example to ${f#"$REPO_ROOT"/}, set expected_account_id to $(env_account "$env") and a new bucket_name, then run this again."
    info "$env has its own account: bucket settings from ${f#"$REPO_ROOT"/}"
  fi
  use_env "$env"
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
    [[ -n "$owner" ]] || die "Set owner in ${f#"$REPO_ROOT"/} or terraform/bootstrap/testing.tfvars."
    var_args+=(-var="owner=$owner")
  fi
  [[ -n "$(hcl_value aws_region "$f")" ]] || var_args+=(-var="aws_region=$region")

  local backend_args=(
    -backend-config="bucket=$bucket"
    -backend-config="key=$SB_KEY"
    -backend-config="region=$region"
  )
  kms_backend_args
  backend_args+=(${KMS_ARGS[@]+"${KMS_ARGS[@]}"})
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
  tf_in "$SB_DIR" "$data" plan -input=false ${file_args[@]+"${file_args[@]}"} -var="import_existing_bucket=$import" ${var_args[@]+"${var_args[@]}"} -out="$plan"
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

# ---- org ----

# org_caller_check <management account>. Stops unless the session is in
# that account and it is the organization's management account. SCPs never
# apply to the management account, so a run from anywhere else is a mistake.
org_caller_check() {
  local want="$1" acct master
  [[ "$want" =~ ^[0-9]{12}$ ]] || die "management_account_id in terraform/org/terraform.tfvars must be a 12 digit account ID."
  acct=$(current_account) || die "No AWS session${AWS_PROFILE:+ for profile $AWS_PROFILE}."
  [[ "$acct" == "$want" ]] || die "Signed in to $acct, but terraform/org runs from the management account $want. Set aws_profile in terraform/org/terraform.tfvars to a profile for $want."
  master=$(aws organizations describe-organization --query Organization.MasterAccountId --output text 2>/dev/null) ||
    die "Can't read the organization from $acct. Is it the management account, with organizations:DescribeOrganization?"
  [[ "$master" == "$want" ]] || die "$acct is in an organization whose management account is $master, not $want."
}

# Moves each account in ou_account_ids into the OU, after a confirm. An
# account already there is skipped. Nothing else moves.
org_move_accounts() {
  local ou ids a parent
  ou=$(tf_in "$ORG_DIR" .terraform output -raw ou_id)
  ids=$(tf_in "$ORG_DIR" .terraform output -json ou_account_ids | jq -r '.[]')
  if [[ -z "$ids" ]]; then
    info "ou_account_ids is empty. No account moved, so the new SCPs cover nothing yet."
    return 0
  fi
  # SCPs only deny. Without an allow (FullAWSAccess, which AWS attaches to
  # every new OU) an account in the OU could do nothing at all.
  aws organizations list-policies-for-target --target-id "$ou" --filter SERVICE_CONTROL_POLICY --query 'Policies[].Id' --output text |
    tr '\t' '\n' | grep -qx p-FullAWSAccess ||
    die "$ou has no FullAWSAccess attached. Attach it (or an allow list of your own) before moving any account in."
  for a in $ids; do
    parent=$(aws organizations list-parents --child-id "$a" --query 'Parents[0].Id' --output text)
    if [[ "$parent" == "$ou" ]]; then
      info "$a is already in $ou"
      continue
    fi
    info "$a is in $parent. Policies on it now:"
    aws organizations list-policies-for-target --target-id "$parent" --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text
    warn "Moving $a to $ou drops the SCPs on $parent for it (root SCPs still apply) and adds the ones on $ou."
    confirm move "move $a into $ou"
    aws organizations move-account --account-id "$a" --source-parent-id "$parent" --destination-parent-id "$ou"
    info "Moved $a into $ou"
  done
}

cmd_org() {
  local f="$ORG_DIR/terraform.tfvars" mgmt profile plan="org.tfplan"
  NO_GITHUB=1
  preflight_common
  check_tfvars_file "$f"
  mgmt=$(hcl_value management_account_id "$f")
  profile=$(hcl_value aws_profile "$f")
  if [[ -n "$profile" ]]; then
    export AWS_PROFILE="$profile"
  fi
  ensure_session
  org_caller_check "$mgmt"
  info "Signed in to the management account $mgmt${AWS_PROFILE:+ (profile $AWS_PROFILE)}"

  CLEANUP+=("$ORG_DIR/$plan")
  tf_in "$ORG_DIR" .terraform init -input=false
  info "[org] plan"
  tf_in "$ORG_DIR" .terraform plan -input=false -out="$plan"
  summarize_plan "$ORG_DIR" .terraform "$plan"
  if ((PLAN_DELETES > 0)); then
    warn "This plan destroys or replaces $PLAN_DELETES resource(s). Read the list above before you confirm."
  fi

  if ((DRY_RUN)); then
    rm -f "$ORG_DIR/$plan"
    info "Dry run: nothing applied, no account moved."
    return 0
  fi

  if ((PLAN_CHANGES > 0)); then
    confirm org "apply the org plan above"
    tf_in "$ORG_DIR" .terraform apply -input=false "$plan"
  else
    info "No changes."
  fi
  rm -f "$ORG_DIR/$plan"
  org_move_accounts
  info "Done. State is in terraform/org/terraform.tfstate (gitignored). Keep a copy."
}

log_init "bootstrap-${TARGET}${DESTROY_ENV:+-$DESTROY_ENV}"
((DRY_RUN)) && info "Dry run"

case "$TARGET" in
  destroy) cmd_destroy ;;
  state-bucket) cmd_state_bucket ;;
  org) cmd_org ;;
  *) cmd_bootstrap ;;
esac
