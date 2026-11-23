#!/usr/bin/env bash
# Push the locally built, smoke-tested and scanned image to ECR under an immutable tag and publish
# its digest (image-build.yml). Requires the image-push role's credentials.
#
# Required environment: AWS_REGION, IMAGE (local image), ECR_REPOSITORY, GITHUB_SHA
set -euo pipefail

for v in AWS_REGION IMAGE ECR_REPOSITORY GITHUB_SHA; do
  [ -n "${!v:-}" ] || { echo "::error::$v is not set"; exit 2; }
done
WORK=${RUNNER_TEMP:-$(mktemp -d)}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
TAG="git-$GITHUB_SHA"
echo "$REGISTRY" >"$WORK/registry"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

if aws ecr describe-images --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=$TAG" --output json >/dev/null 2>&1; then
  # Immutable tags: a re-run of the same commit cannot overwrite the published image.
  PUSHED="no: this commit was already published (immutable tag); the existing image is kept"
else
  docker tag "$IMAGE" "$REGISTRY/$ECR_REPOSITORY:$TAG"
  docker push --quiet "$REGISTRY/$ECR_REPOSITORY:$TAG"
  PUSHED="yes"
fi

DIGEST=$(aws ecr describe-images --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=$TAG" --output json | jq -r '.imageDetails[0].imageDigest')
[[ $DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::could not read the pushed image digest"; exit 1; }

echo "Published $ECR_REPOSITORY:$TAG = $DIGEST"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "digest=$DIGEST" >>"$GITHUB_OUTPUT"; fi
{
  echo "## image-build: $ECR_REPOSITORY"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Tag (immutable) | \`$TAG\` |"
  echo "| **Digest** | \`$DIGEST\` |"
  echo "| Pushed now | $PUSHED |"
  echo "| Gates passed before push | build, hardened smoke test, Trivy (HIGH/CRITICAL fixable = 0); SBOM attached |"
  echo
  echo "To release it: run **app-deploy** with \`image_digest = $DIGEST\`, then approve the \`dev-deploy\` environment."
  echo "First release only (no ECS service yet): set the repository variable \`SERVICE_IMAGE_DIGEST\` to this digest, then terraform-plan and terraform-apply (docs/release-runbook.md)."
} >>"$SUMMARY"
