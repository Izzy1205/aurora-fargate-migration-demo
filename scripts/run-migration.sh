#!/usr/bin/env bash
# Run a one-off DB task (Flyway, or the db-logins setup) once inside the VPC,
# wait for it, print its logs and fail unless the container exited 0.
#
# Required env: CLUSTER, TASK_DEFINITION, SUBNETS (comma separated),
#               SECURITY_GROUP, LOG_GROUP
# Optional env: CONTAINER (default migrate), also the log stream prefix
set -euo pipefail

: "${CLUSTER:?}" "${TASK_DEFINITION:?}" "${SUBNETS:?}" "${SECURITY_GROUP:?}" "${LOG_GROUP:?}"
container=${CONTAINER:-migrate}

echo "Starting ${container} task from ${TASK_DEFINITION}"
run_out=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEFINITION" \
  --launch-type FARGATE \
  --count 1 \
  --started-by "gha-${GITHUB_RUN_ID:-local}" \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SECURITY_GROUP}],assignPublicIp=DISABLED}" \
  --output json)

task_arn=$(jq -r '.tasks[0].taskArn // empty' <<<"$run_out")
if [[ -z "$task_arn" ]]; then
  echo "run-task did not start a task:" >&2
  jq '.failures' <<<"$run_out" >&2
  exit 1
fi
echo "Task: ${task_arn}"

# Polls every 6s for up to 10 minutes. A paused Aurora cluster resumes in
# well under a minute, and Flyway retries the connection meanwhile.
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn"

desc=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" --output json)
exit_code=$(jq -r --arg c "$container" '.tasks[0].containers[] | select(.name == $c) | .exitCode // "none"' <<<"$desc")
stop_reason=$(jq -r '.tasks[0].stoppedReason // ""' <<<"$desc")

task_id=${task_arn##*/}
echo "----- ${container} output -----"
aws logs get-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name "${container}/${container}/${task_id}" \
  --start-from-head \
  --query 'events[].message' --output text | tr '\t' '\n' || echo "(no logs found)"
echo "-------------------------"

if [[ "$exit_code" != "0" ]]; then
  echo "${container} task failed: exit code ${exit_code}. ${stop_reason}" >&2
  exit 1
fi
echo "${container} task succeeded."
