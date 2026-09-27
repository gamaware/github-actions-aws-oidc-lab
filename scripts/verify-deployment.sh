#!/usr/bin/env bash
# Verify that an ECS deployment is really serving the new revision.
#
# "Service stable" is not enough on its own: with the circuit breaker on, a
# failed rollout rolls back and the service becomes stable on the OLD
# revision. This script checks that:
#   1. the PRIMARY deployment uses the expected task definition revision and
#      its rollout completed (no rollback);
#   2. enough tasks of that revision are RUNNING and HEALTHY (the container
#      health check calls /health), and run the expected image digest;
#   3. optionally, APP_URL/health answers and APP_URL/ reports EXPECTED_VERSION.
#
# The deploy workflow runs it after every rollout; it runs the same way from a
# laptop with read access to the service.
#
# Required: ECS_CLUSTER, ECS_SERVICE, EXPECTED_TASK_DEFINITION (ARN),
#           EXPECTED_IMAGE_DIGEST (sha256:...)
# Optional: APP_URL, EXPECTED_VERSION, ATTEMPTS (default 20), INTERVAL (default 15)

set -euo pipefail

: "${ECS_CLUSTER:?set ECS_CLUSTER}"
: "${ECS_SERVICE:?set ECS_SERVICE}"
: "${EXPECTED_TASK_DEFINITION:?set EXPECTED_TASK_DEFINITION}"
: "${EXPECTED_IMAGE_DIGEST:?set EXPECTED_IMAGE_DIGEST}"
ATTEMPTS="${ATTEMPTS:-20}"
INTERVAL="${INTERVAL:-15}"
CONTAINER_NAME="${CONTAINER_NAME:-app}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

primary="$(aws ecs describe-services \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE" \
  --query "services[0].deployments[?status=='PRIMARY'] | [0]" \
  --output json)"

[[ "$primary" != "null" ]] || fail "No PRIMARY deployment found for $ECS_SERVICE."

primary_task_definition="$(jq -r '.taskDefinition' <<<"$primary")"
rollout_state="$(jq -r '.rolloutState // "UNKNOWN"' <<<"$primary")"
desired_count="$(jq -r '.desiredCount' <<<"$primary")"

if [[ "$primary_task_definition" != "$EXPECTED_TASK_DEFINITION" ]]; then
  fail "PRIMARY deployment runs $primary_task_definition, not $EXPECTED_TASK_DEFINITION. The circuit breaker probably rolled back."
fi
[[ "$rollout_state" == "COMPLETED" ]] || fail "Rollout state is $rollout_state, expected COMPLETED."
echo "PRIMARY deployment uses $primary_task_definition and its rollout completed."

if [[ "$desired_count" -eq 0 ]]; then
  echo "::warning::desired_count is 0, so no task runs the new revision. Scale the service up to verify task health."
  exit 0
fi

healthy=0
for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
  healthy=0
  # read -a instead of mapfile, so the script also runs on the bash 3.2 that
  # ships with macOS. Task ARNs contain no whitespace.
  # A failed call (for example AccessDenied) stops the script here, instead of
  # being read as "no tasks yet".
  task_list="$(aws ecs list-tasks \
    --cluster "$ECS_CLUSTER" \
    --service-name "$ECS_SERVICE" \
    --desired-status RUNNING \
    --query 'taskArns[]' \
    --output text)"
  read -r -a task_arns <<<"$task_list"

  if ((${#task_arns[@]} > 0)) && [[ "${task_arns[0]}" != "None" ]]; then
    healthy="$(aws ecs describe-tasks \
      --cluster "$ECS_CLUSTER" \
      --tasks "${task_arns[@]}" \
      --output json |
      jq --arg td "$EXPECTED_TASK_DEFINITION" \
        --arg digest "$EXPECTED_IMAGE_DIGEST" \
        --arg name "$CONTAINER_NAME" \
        '[.tasks[]
          | select(.taskDefinitionArn == $td
                   and .lastStatus == "RUNNING"
                   and .healthStatus == "HEALTHY")
          | select(any(.containers[]; .name == $name and .imageDigest == $digest))
        ] | length')"
  fi

  echo "Attempt $attempt/$ATTEMPTS: $healthy of $desired_count tasks healthy on the new revision and digest."
  if ((healthy >= desired_count)); then
    break
  fi
  if ((attempt < ATTEMPTS)); then
    sleep "$INTERVAL"
  fi
done

((healthy >= desired_count)) || fail "Only $healthy of $desired_count tasks became healthy on the new revision."

if [[ -n "${APP_URL:-}" ]]; then
  health="$(curl --fail --silent --show-error --max-time 5 "$APP_URL/health")"
  [[ "$(jq -r '.status' <<<"$health")" == "ok" ]] || fail "$APP_URL/health returned: $health"
  echo "$APP_URL/health returned ok."

  if [[ -n "${EXPECTED_VERSION:-}" ]]; then
    version="$(curl --fail --silent --show-error --max-time 5 "$APP_URL/" | jq -r '.version')"
    [[ "$version" == "$EXPECTED_VERSION" ]] || fail "$APP_URL/ reports version $version, expected $EXPECTED_VERSION."
    echo "$APP_URL/ reports version $version."
  fi
fi

echo "Deployment verified."
