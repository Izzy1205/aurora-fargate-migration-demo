#!/usr/bin/env bash
# Checks how teardown.sh finds, stops and waits on AWS Backup jobs before
# the data destroy, with a fake aws and no AWS. Covers no jobs, a running
# job that gets stopped and clears, a copy job that is only waited on, the
# dry run listing without stopping, and the timeout.
#
#   bash scripts/tests/teardown-backup-jobs.sh
# The functions come in through eval, so shellcheck can't see them use the
# values and fakes set here.
# shellcheck disable=SC2034,SC2329
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$here/../lib.sh"

# Pull just these functions out of teardown.sh so its main part doesn't run.
fns="backup_vaults active_backup_jobs indent show_backup_jobs clear_backup_jobs"
eval "$(awk -v names="$fns" '
  BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i] "() {"] = 1 }
  /^(BACKUP|COPY)_[A-Z_]+=/ { print; next }
  !inside { for (k in want) if (index($0, k) == 1) { print; inside = 1; next } ; next }
  { print; if ($0 == "}") inside = 0 }
' "$here/../teardown.sh")"
for f in $fns; do
  declare -F "$f" >/dev/null || { echo "$f not found in teardown.sh"; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/testing"
printf 'locals {\n  aws_region = "us-east-2"\n  dr_region = "us-west-2"\n  dr_copy_enabled = false\n}\n' >"$tmp/testing/env.hcl"

PROJECT=migdemo
ACCOUNT_ID=111111111111
TARGET=testing
BACKUP_POLL_SECONDS=1
env_dir() { echo "$tmp/$1"; }
env_region() { echo us-east-2; }
session_check() { :; }
sleep() { :; }

# Fake aws. $tmp/job holds "<state>" of one backup job, $tmp/copy the
# state of one copy job, $tmp/sticky makes stop do nothing. Every call is
# logged to $tmp/calls.
aws() {
  echo "$*" >>"$tmp/calls"
  local sub="$2" st="" a prev=""
  for a in "$@"; do
    [[ "$prev" == --by-state ]] && st="$a"
    prev="$a"
  done
  case "$sub" in
    list-backup-vaults)
      echo '{"BackupVaultList":[{"BackupVaultName":"migdemo-testing-aurora"},{"BackupVaultName":"migdemo-stage-aurora"}]}'
      ;;
    list-backup-jobs)
      local cur
      cur=$(cat "$tmp/job" 2>/dev/null || true)
      if [[ -n "$cur" && "$cur" == "$st" ]]; then
        printf '{"BackupJobs":[{"BackupJobId":"job-1","State":"%s","BackupVaultName":"migdemo-testing-aurora"}]}\n' "$cur"
        # A stopped job goes ABORTING, then ABORTED on the next look.
        if [[ "$cur" == ABORTING ]]; then echo ABORTED >"$tmp/job"; fi
      else
        echo '{"BackupJobs":[]}'
      fi
      ;;
    list-copy-jobs)
      local cur
      cur=$(cat "$tmp/copy" 2>/dev/null || true)
      if [[ -n "$cur" && "$cur" == "$st" ]]; then
        printf '{"CopyJobs":[{"CopyJobId":"copy-1","State":"%s","SourceBackupVaultArn":"arn:aws:backup:us-east-2:111111111111:backup-vault:migdemo-testing-aurora"},{"CopyJobId":"copy-x","State":"%s","SourceBackupVaultArn":"arn:aws:backup:us-east-2:111111111111:backup-vault:migdemo-stage-aurora"}]}\n' "$cur" "$cur"
        # Done after two looks.
        if [[ -f "$tmp/copyseen" ]]; then echo COMPLETED >"$tmp/copy"; else touch "$tmp/copyseen"; fi
      else
        echo '{"CopyJobs":[]}'
      fi
      ;;
    stop-backup-job)
      [[ -f "$tmp/sticky" ]] || echo ABORTING >"$tmp/job"
      ;;
    *) return 1 ;;
  esac
}

reset() { rm -f "$tmp/job" "$tmp/copy" "$tmp/copyseen" "$tmp/sticky" "$tmp/calls"; touch "$tmp/calls"; }

fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fails=1; }

# 1. No jobs: nothing stopped, returns 0.
reset
BACKUP_WAIT_SECONDS=5
if out=$(clear_backup_jobs testing 2>&1) && ! grep -q stop-backup-job "$tmp/calls" && [[ "$out" == *"no active backup"* ]]; then
  ok "no jobs"
else bad "no jobs: $out"; fi

# 2. A running job is stopped and then clears.
reset
echo RUNNING >"$tmp/job"
if out=$(clear_backup_jobs testing 2>&1) && grep -q 'stop-backup-job --region us-east-2 --backup-job-id job-1' "$tmp/calls" &&
  [[ "$out" == *"no active backup jobs left"* ]]; then
  ok "running job stopped, then clears"
else bad "running job: $out"; fi

# 3. Only the env's own vault is checked, by name.
if grep -q -- '--by-backup-vault-name migdemo-testing-aurora' "$tmp/calls" && ! grep -q 'migdemo-stage-aurora' "$tmp/calls"; then
  ok "only this env's vault"
else bad "vault filter: $(cat "$tmp/calls")"; fi

# 4. A copy job from this env's vault is waited on, not stopped. The other
# env's copy job doesn't count.
reset
echo RUNNING >"$tmp/copy"
if out=$(clear_backup_jobs testing 2>&1) && ! grep -q stop-backup-job "$tmp/calls" &&
  [[ "$out" == *"copy-1"* && "$out" != *"copy-x"* && "$out" == *"no active backup jobs left"* ]]; then
  ok "copy job waited on"
else bad "copy job: $out"; fi

# 5. Dry run lists only (teardown.sh calls show_backup_jobs then exits).
reset
echo RUNNING >"$tmp/job"
if ! out=$(show_backup_jobs testing 2>&1) && [[ "$out" == *"job-1 RUNNING"* ]] && ! grep -q stop-backup-job "$tmp/calls"; then
  ok "dry run lists, never stops"
else bad "dry run: $out"; fi
# And the dry run path in teardown.sh exits before anything that stops.
if awk '/^if \(\(DRY_RUN\)\); then$/,/^fi$/' "$here/../teardown.sh" | grep -q 'exit 0' &&
  ! awk '/show_backup_jobs "\$env" \|\|/{f=1} f&&/Dry run: nothing destroyed/{exit} f' "$here/../teardown.sh" | grep -q clear_backup_jobs; then
  ok "dry run exits before clear_backup_jobs"
else bad "dry run path in teardown.sh"; fi

# 6. A job that won't stop times out with a clear message.
reset
echo RUNNING >"$tmp/job"
touch "$tmp/sticky"
BACKUP_WAIT_SECONDS=3
if ! out=$( (clear_backup_jobs testing) 2>&1) && [[ "$out" == *"still active after 3s"* && "$out" == *"Nothing in data was destroyed"* ]]; then
  ok "timeout"
else bad "timeout: $out"; fi

# 7. A failed vault lookup stops, it doesn't read as no jobs.
reset
aws() { echo "$*" >>"$tmp/calls"; return 1; }
if ! out=$( (clear_backup_jobs testing) 2>&1) && [[ "$out" == *"could not list backup vaults"* ]]; then
  ok "lookup error stops"
else bad "lookup error: $out"; fi

((fails == 0)) && echo "All good." || exit 1
