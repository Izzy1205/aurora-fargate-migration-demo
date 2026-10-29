#!/usr/bin/env bash
# Runs a one-off DB task in the VPC, prints its logs, fails unless it exits 0.
# Needs CLUSTER, TASK_DEFINITION, SUBNETS, SECURITY_GROUP, LOG_GROUP. Optional CONTAINER.
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

# Up to 10 min. A paused Aurora resumes well within that.
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
