#!/usr/bin/env bash
# Registers a new task def revision with one container's image swapped.
# Usage: register-task-def.sh <family> <container-name> <image>
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <family> <container-name> <image>" >&2
  exit 2
fi

family=$1
container=$2
image=$3

current=$(aws ecs describe-task-definition --task-definition "$family" \
  --query taskDefinition --output json)

new=$(jq --arg c "$container" --arg img "$image" '
  .containerDefinitions |= map(if .name == $c then .image = $img else . end)
  | {family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
     volumes, placementConstraints, requiresCompatibilities, cpu, memory,
     runtimePlatform}
  | with_entries(select(.value != null))' <<<"$current")

aws ecs register-task-definition --cli-input-json "$new" \
  --query taskDefinition.taskDefinitionArn --output text
