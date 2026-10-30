#!/usr/bin/env bash
# Register a new revision of an ECS task definition with one container's
# image swapped. Everything else (roles, env, secret ARNs) is copied from the
# latest revision, which Terraform owns.
#
# The image must be pinned by digest (<repo>@sha256:<64 hex>), so the task
# runs exactly the bytes that were scanned and pushed. The optional revision
# (the commit SHA tag) is written to the container's
# org.opencontainers.image.revision Docker label so people can still see which
# commit a revision runs: tag for humans, digest for deployment.
#
# Usage: register-task-def.sh <family> <container-name> <image@digest> [revision]
# Prints the new task definition ARN.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <family> <container-name> <image@sha256:digest> [revision]" >&2
  exit 2
fi

family=$1
container=$2
image=$3
revision=${4:-}

if [[ ! "$image" =~ ^[^@[:space:]]+@sha256:[a-f0-9]{64}$ ]]; then
  echo "image must be pinned by digest (<repo>@sha256:<64 hex>), got: $image" >&2
  exit 2
fi

current=$(aws ecs describe-task-definition --task-definition "$family" \
  --query taskDefinition --output json)

new=$(jq --arg c "$container" --arg img "$image" --arg rev "$revision" '
  .containerDefinitions |= map(
    if .name == $c then
      .image = $img
      | if $rev != "" then
          .dockerLabels = ((.dockerLabels // {}) + {"org.opencontainers.image.revision": $rev})
        else . end
    else . end)
  | {family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
     volumes, placementConstraints, requiresCompatibilities, cpu, memory,
     runtimePlatform}
  | with_entries(select(.value != null))' <<<"$current")

aws ecs register-task-definition --cli-input-json "$new" \
  --query taskDefinition.taskDefinitionArn --output text
