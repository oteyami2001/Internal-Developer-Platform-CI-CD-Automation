#!/usr/bin/env bash
# Release one digest-pinned image to an environment's ECS service, as run by app-deploy.yml
# (after the owner approves the `<env>-deploy` GitHub environment).
#
#   app_deploy.sh <env>
#
#   1. The image must exist in this account's ECR repository, by DIGEST. Only the image-build
#      pipeline role can push there (repository policy), after its smoke test and Trivy gate.
#   2. The service must already exist: the first release is created by Terraform
#      (SERVICE_IMAGE_DIGEST, see tf_ci.sh). This script never creates infrastructure.
#   3. A new task-definition revision is derived from the family's latest ACTIVE revision with ONLY
#      the application container's image changed. CPU, memory, roles, user, read-only filesystem,
#      capabilities and logging stay exactly as Terraform defined them.
#   4. The service is updated and the script waits for THAT deployment's rolloutState. A
#      "services-stable" wait is not enough: after a circuit-breaker rollback the service is
#      stable again, on the OLD revision. FAILED (rolled back) or a timeout fails the job.
#   5. Verified: the new revision is the PRIMARY deployment and the target group has healthy targets.
#
# Required environment: AWS_ROLE_ARN, AWS_REGION, IMAGE_DIGEST (sha256:<64 hex>)
# Optional: DEPLOY_TIMEOUT_SECONDS (default 900), DEPLOY_POLL_SECONDS (default 15)
set -euo pipefail

ENV=${1:?usage: app_deploy.sh <env>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${RUNNER_TEMP:-$(mktemp -d)}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}
TIMEOUT=${DEPLOY_TIMEOUT_SECONDS:-900}
POLL=${DEPLOY_POLL_SECONDS:-15}

case "$ENV" in dev | staging | prod) ;; *) echo "unknown environment: $ENV" >&2; exit 2 ;; esac
for v in AWS_ROLE_ARN AWS_REGION IMAGE_DIGEST; do
  [ -n "${!v:-}" ] || { echo "::error::$v is not set"; exit 2; }
done
[[ $IMAGE_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::image_digest must be sha256:<64 lowercase hex> (from the image-build summary). Tags are not accepted."; exit 2; }

ACCOUNT=$(cut -d: -f5 <<<"$AWS_ROLE_ARN")
[[ $ACCOUNT =~ ^[0-9]{12}$ ]] || { echo "::error::cannot read an account ID from AWS_ROLE_ARN"; exit 2; }
CALLER=$(aws sts get-caller-identity --query Account --output text)
[ "$CALLER" = "$ACCOUNT" ] || { echo "::error::credentials are for another account"; exit 1; }

SERVICE=$(python "$ROOT/scripts/validate_service.py" --render "$ENV" "$ROOT/apps/sample-api/service.yaml" | jq -r .service_name)
CLUSTER="idp-$ENV"
FAMILY="$CLUSTER-$SERVICE"
REPO="idp/$SERVICE"
IMAGE="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO@$IMAGE_DIGEST"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_S=$(date +%s)

# --- 1. The image exists in our repository ----------------------------------------------------
if ! aws ecr describe-images --repository-name "$REPO" --image-ids "imageDigest=$IMAGE_DIGEST" --output json >"$WORK/image.json"; then
  echo "::error::Image $IMAGE_DIGEST is not in $REPO. Only images published by image-build.yml can be deployed."
  exit 1
fi
IMAGE_TAGS=$(jq -r '.imageDetails[0].imageTags // [] | join(", ")' "$WORK/image.json")
# ECR's own scan on push: reported, not gated (the Trivy gate in image-build.yml is the gate; ECR
# basic scanning also lists vulnerabilities that have no fix yet).
SCAN=$(aws ecr describe-image-scan-findings --repository-name "$REPO" --image-id "imageDigest=$IMAGE_DIGEST" --output json 2>/dev/null \
  | jq -r '(.imageScanStatus.status // "UNKNOWN") + " " + ((.imageScanFindings.findingSeverityCounts // {}) | to_entries | map("\(.key)=\(.value)") | join(" "))' \
  || echo "UNAVAILABLE")

# --- 2. The service exists (Terraform created it) ---------------------------------------------
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --output json >"$WORK/service.json"
if ! jq -e '.services[0].status == "ACTIVE"' "$WORK/service.json" >/dev/null; then
  echo "::error::Service $SERVICE does not exist in cluster $CLUSTER yet. The first release is created by Terraform: set SERVICE_IMAGE_DIGEST, then run terraform-plan and terraform-apply (docs/release-runbook.md)."
  exit 1
fi
PREVIOUS=$(jq -r '.services[0].taskDefinition' "$WORK/service.json")

# --- 3. New revision: only the application image changes --------------------------------------
aws ecs describe-task-definition --task-definition "$FAMILY" --output json >"$WORK/current-td.json"
jq -e --arg name "$SERVICE" '[.taskDefinition.containerDefinitions[] | select(.name == $name)] | length == 1' "$WORK/current-td.json" >/dev/null \
  || { echo "::error::task definition $FAMILY must have exactly one container named $SERVICE"; exit 1; }
jq --arg name "$SERVICE" --arg image "$IMAGE" --arg env "$ENV" --arg digest "$IMAGE_DIGEST" '
  .taskDefinition
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
        .registeredAt, .registeredBy, .deregisteredAt)
  | .containerDefinitions |= map(if .name == $name then .image = $image else . end)
  | .tags = [
      {key: "Project", value: "idp"}, {key: "Environment", value: $env},
      {key: "ManagedBy", value: "app-deploy"}, {key: "ImageDigest", value: $digest},
      {key: "Repository", value: "oteyami2001/Internal-Developer-Platform-CI-CD-Automation"}
    ]' "$WORK/current-td.json" >"$WORK/new-td.json"
NEW=$(aws ecs register-task-definition --cli-input-json "file://$WORK/new-td.json" --output json | jq -r .taskDefinition.taskDefinitionArn)
[[ $NEW == *":task-definition/$FAMILY:"* ]] || { echo "::error::registering the task definition failed"; exit 1; }
echo "Registered ${NEW##*/} (image $IMAGE_DIGEST)"

# --- 4. Roll out and wait for THIS deployment ----------------------------------------------------
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$NEW" --output json >/dev/null
ROLLOUT_START_S=$(date +%s)
while :; do
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --output json >"$WORK/service.json"
  STATE=$(jq -r --arg td "$NEW" '[.services[0].deployments[] | select(.taskDefinition == $td)][0].rolloutState // "MISSING"' "$WORK/service.json")
  REASON=$(jq -r --arg td "$NEW" '[.services[0].deployments[] | select(.taskDefinition == $td)][0].rolloutStateReason // ""' "$WORK/service.json")
  echo "$(date -u +%H:%M:%S) rollout ${NEW##*/}: $STATE"
  case "$STATE" in COMPLETED | FAILED | MISSING) break ;; esac
  [ $(($(date +%s) - ROLLOUT_START_S)) -lt "$TIMEOUT" ] || { REASON="timed out after ${TIMEOUT}s"; break; }
  sleep "$POLL"
done
ELAPSED=$(($(date +%s) - START_S))

result() {
  {
    echo "## app-deploy: $SERVICE to $ENV"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Result | **$1** |"
    echo "| Image digest | \`$IMAGE_DIGEST\` |"
    echo "| Image tags | ${IMAGE_TAGS:-none} |"
    echo "| ECR scan on push | $SCAN |"
    echo "| Task definition | \`${PREVIOUS##*/}\` → \`${NEW##*/}\` |"
    echo "| Rollout | $STATE ${REASON:+($REASON)} |"
    echo "| Healthy targets | ${HEALTHY:-not checked} |"
    echo "| Started (UTC) / duration | $STARTED / ${ELAPSED}s |"
    echo "| Commit / run | \`${GITHUB_SHA:-local}\` / ${GITHUB_RUN_ID:-local} |"
  } >>"$SUMMARY"
}

if [ "$STATE" != COMPLETED ]; then
  result "FAILED"
  echo "::error::Deployment of ${NEW##*/} did not complete ($STATE${REASON:+: $REASON}). The circuit breaker keeps or restores the previous revision (${PREVIOUS##*/}); check the service events and the log group."
  exit 1
fi

# --- 5. Verify -------------------------------------------------------------------------------------
PRIMARY=$(jq -r '.services[0].deployments[] | select(.status == "PRIMARY") | .taskDefinition' "$WORK/service.json")
if [ "$PRIMARY" != "$NEW" ]; then
  result "FAILED"
  echo "::error::rollout reported COMPLETED but the primary deployment runs ${PRIMARY##*/}, not ${NEW##*/}"
  exit 1
fi
TG=$(jq -r '.services[0].loadBalancers[0].targetGroupArn' "$WORK/service.json")
HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG" --output json | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length')
if [ "$HEALTHY" -lt 1 ]; then
  result "FAILED"
  echo "::error::no healthy targets behind the load balancer"
  exit 1
fi
result "DEPLOYED"
echo "Deployed ${NEW##*/}: $HEALTHY healthy target(s), ${ELAPSED}s."
