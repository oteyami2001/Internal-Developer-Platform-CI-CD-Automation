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
# Releases are tagged git-<commit>; rollback-drill images drill-crash-<commit> (drill-image.yml).
TAG_PREFIX=${TAG_PREFIX:-git}
[[ $TAG_PREFIX =~ ^(git|drill-crash)$ ]] || { echo "::error::TAG_PREFIX must be git or drill-crash"; exit 2; }
TAG="$TAG_PREFIX-$GITHUB_SHA"
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

aws ecr describe-images --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=$TAG" --output json >"$WORK/pushed.json"
DIGEST=$(jq -r '.imageDetails[0].imageDigest' "$WORK/pushed.json")
[[ $DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::could not read the pushed image digest"; exit 1; }
# The tag must point at ONE image manifest, not an image index. An index (for example from BuildKit
# provenance attestations) leaves its child manifests UNTAGGED in ECR, and the lifecycle rule
# "expire untagged after 1 day" may then delete the layers a running service still needs to pull.
MEDIA=$(jq -r '.imageDetails[0].imageManifestMediaType // "unknown"' "$WORK/pushed.json")
case "$MEDIA" in
  application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json) ;;
  *) echo "::error::$ECR_REPOSITORY:$TAG is a $MEDIA, not a single image manifest. Build with --provenance=false --sbom=false (make image)."; exit 1 ;;
esac

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
  if [ "$TAG_PREFIX" = drill-crash ]; then
    echo "**Rollback drill image: it exits on start.** Deploying it with **app-deploy** must FAIL and the circuit breaker must roll back (docs/rollback-runbook.md section 2)."
  else
    echo "To release it: run **app-deploy** with \`image_digest = $DIGEST\`, then approve the \`dev-deploy\` environment."
  fi
  echo "First release only (no ECS service yet): set the repository variable \`SERVICE_IMAGE_DIGEST\` to this digest, then terraform-plan and terraform-apply (docs/release-runbook.md)."
} >>"$SUMMARY"
