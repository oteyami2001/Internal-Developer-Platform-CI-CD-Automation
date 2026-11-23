#!/usr/bin/env bash
# Terraform plan/apply for one environment, as run by terraform-plan.yml, terraform-apply.yml,
# drift-detection.yml and cleanup.yml. Every workflow calls THIS script, so an apply re-creates the
# plan exactly the way the reviewed plan was created.
#
#   tf_ci.sh plan  <env>   plan, print a reviewable summary and the PLAN DIGEST
#   tf_ci.sh apply <env>   re-plan; refuse unless the digest equals $EXPECTED_DIGEST; apply that plan
#   tf_ci.sh drift <env>   plan only; exit 3 and write $RUNNER_TEMP/drift.md if real infrastructure
#                          differs from the code. Never applies (drift is reported, not fixed).
#
# TF_MODE=destroy (cleanup): `plan` plans the removal of the whole environment stack, `apply`
# destroys exactly that reviewed plan and then VERIFIES nothing is left. Destroy additionally needs
# CONFIRM_DESTROY=destroy-<env>. The digest covers the mode, so a reviewed destroy digest can never
# be used for a normal apply, nor the reverse. Bootstrap resources (state, CI roles, ECR, budget)
# are in a different configuration and are never touched.
#
# Why a digest instead of uploading the plan file: this repository is public, and a plan file
# contains the plaintext values of every variable (alert e-mail, operator IP) and state data.
# The digest is a SHA-256 over every planned change (address, action, after-values). Any change in
# code, variables or real infrastructure between review and apply produces a different digest, and
# the apply stops. Nothing sensitive is stored as an artifact.
#
# Required environment (set by the workflow from GitHub environment variables/secrets):
#   AWS_ROLE_ARN, AWS_REGION, TF_STATE_BUCKET, ALLOWED_INGRESS_CIDR, TF_VAR_alert_email
# Optional: SERVICE_IMAGE_DIGEST (sha256:<64 hex> of the image that CREATES the ECS service; empty =
#           infrastructure only), EXPECTED_DIGEST (apply)
#
# Release ownership: Terraform creates the service ONCE with SERVICE_IMAGE_DIGEST. Every later
# release is a new task-definition revision registered by app-deploy.yml (scripts/app_deploy.sh).
# A plan that would DELETE the running ECS service (for example because SERVICE_IMAGE_DIGEST was
# removed) is refused here: removing a service is a cleanup decision, never a side effect.
set -euo pipefail

CMD=${1:?usage: tf_ci.sh plan|apply <env>}
ENV=${2:?usage: tf_ci.sh plan|apply <env>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STACK="$ROOT/terraform/stack"
WORK=${RUNNER_TEMP:-$(mktemp -d)}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}

case "$ENV" in dev | staging | prod) ;; *) echo "unknown environment: $ENV" >&2; exit 2 ;; esac
case "$CMD" in plan | apply | drift) ;; *) echo "unknown command: $CMD" >&2; exit 2 ;; esac
MODE=${TF_MODE:-apply}
case "$MODE" in apply | destroy) ;; *) echo "TF_MODE must be apply or destroy" >&2; exit 2 ;; esac
if [ "$MODE" = destroy ] && [ "$CMD" = drift ]; then echo "drift detection never runs in destroy mode" >&2; exit 2; fi
if [ "$MODE" = destroy ] && [ "$CMD" = apply ] && [ "${CONFIRM_DESTROY:-}" != "destroy-$ENV" ]; then
  echo "::error::Destroying $ENV needs CONFIRM_DESTROY=destroy-$ENV (typed in the cleanup workflow)"
  exit 2
fi
PLAN_FLAGS=()
if [ "$MODE" = destroy ]; then PLAN_FLAGS=(-destroy); fi
for v in AWS_ROLE_ARN AWS_REGION TF_STATE_BUCKET ALLOWED_INGRESS_CIDR TF_VAR_alert_email; do
  [ -n "${!v:-}" ] || { echo "::error::$v is not set (configure the GitHub environment, docs/dev-deployment-runbook.md)"; exit 2; }
done

# --- Account guard: the role's account must be the account we are actually in ---
ACCOUNT=$(cut -d: -f5 <<<"$AWS_ROLE_ARN")
[[ $ACCOUNT =~ ^[0-9]{12}$ ]] || { echo "::error::cannot read an account ID from AWS_ROLE_ARN"; exit 2; }
CALLER=$(aws sts get-caller-identity --query Account --output text)
[ "$CALLER" = "$ACCOUNT" ] || { echo "::error::credentials are for another account"; exit 1; }
export TF_VAR_aws_account_id=$ACCOUNT
export TF_VAR_allowed_ingress_cidrs
TF_VAR_allowed_ingress_cidrs=$(jq -cn --arg c "$ALLOWED_INGRESS_CIDR" '[$c]')
export TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1

# --- Service settings from the validated manifest (never hand-written) ---
python "$ROOT/scripts/validate_service.py" --render "$ENV" "$ROOT/apps/sample-api/service.yaml" \
  | jq '{service: .}' >"$WORK/service.tfvars.json"

# --- Initial image of the service: an ECR image of THIS account, pinned by digest ---
if [ -n "${SERVICE_IMAGE_DIGEST:-}" ]; then
  [[ $SERVICE_IMAGE_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::SERVICE_IMAGE_DIGEST must be sha256:<64 lowercase hex> (from the image-build summary)"; exit 2; }
  SERVICE_NAME=$(jq -r '.service.service_name' "$WORK/service.tfvars.json")
  export TF_VAR_service_image="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/idp/$SERVICE_NAME@$SERVICE_IMAGE_DIGEST"
fi

terraform -chdir="$STACK" init -input=false -lockfile=readonly -no-color \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=envs/$ENV/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true" >/dev/null

set +e
terraform -chdir="$STACK" plan "${PLAN_FLAGS[@]}" -input=false -no-color -lock-timeout=5m -detailed-exitcode \
  -var-file="../envs/$ENV/terraform.tfvars" -var-file="$WORK/service.tfvars.json" \
  -out="$WORK/tfplan" >"$WORK/plan.txt"
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  cat "$WORK/plan.txt"
  echo "::error::terraform plan failed"
  exit 1
fi

terraform -chdir="$STACK" show -json "$WORK/tfplan" >"$WORK/plan.json"
# Fail closed: an empty or non-plan document would hash to the same digest every time and turn the
# review gate into a no-op. Only a real Terraform plan document (format_version) is accepted.
if ! jq -e 'type == "object" and has("format_version")' "$WORK/plan.json" >/dev/null 2>&1; then
  echo "::error::terraform show -json did not produce a plan document; refusing to continue"
  exit 1
fi
# Never delete the running service as a side effect (see header). Replacing it is a delete too.
# Only the reviewed, confirmed cleanup (TF_MODE=destroy) may remove it.
if [ "$MODE" != destroy ] && jq -e '[.resource_changes[]? | select((.address | test("^module\\.service\\[[0-9]+\\]\\.aws_ecs_service\\."))
    and (.change.actions | index("delete")))] | length > 0' "$WORK/plan.json" >/dev/null; then
  echo "::error::Refusing: this plan would DELETE the running ECS service. If SERVICE_IMAGE_DIGEST was removed or emptied, set it back. Removing an environment is done by the cleanup workflow, not by a plan side effect."
  exit 1
fi
# Canonical, order-independent description of every change, prefixed with the mode; hashed, never
# published in clear.
DIGEST=$({
  printf 'mode=%s\n' "$MODE"
  jq -S -c '[.resource_changes[]? | select(.change.actions != ["no-op"])
    | {address, actions: .change.actions, after: .change.after, after_unknown: .change.after_unknown}]
    | sort_by(.address)' "$WORK/plan.json"
} | sha256sum | cut -d' ' -f1)
PLAN_LINE=$(grep -E '^(Plan:|No changes\.)' "$WORK/plan.txt" | head -1 || true)

{
  echo "## terraform $CMD ($MODE): $ENV"
  echo
  echo "- Commit: \`${GITHUB_SHA:-local}\`"
  echo "- Result: **${PLAN_LINE:-see log}**"
  echo "- Plan digest: \`$DIGEST\`"
  echo
  echo "| Action | Resource |"
  echo "|---|---|"
  jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "| \(.change.actions | join("/")) | `\(.address)` |"' "$WORK/plan.json"
} >>"$SUMMARY"

if [ "$CMD" = drift ]; then
  if [ "$rc" -eq 0 ]; then
    echo "No drift: $ENV matches the code."
    echo "No drift: real infrastructure matches the code." >>"$SUMMARY"
    exit 0
  fi
  # Report addresses and actions only: no values (a public issue must never carry IDs or variables).
  {
    echo "Scheduled drift detection found differences between the code on \`main\` and real infrastructure in **$ENV**."
    echo
    echo "- Detected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Commit: \`${GITHUB_SHA:-local}\`"
    echo "- Result: **${PLAN_LINE:-see run}**"
    echo
    echo "| Action | Resource |"
    echo "|---|---|"
    jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "| \(.change.actions | join("/")) | `\(.address)` |"' "$WORK/plan.json"
    echo
    echo "Nothing was changed. Resolve it: codify the manual change in Terraform (pull request), or restore the"
    echo "code's state with terraform-plan, review, approve and terraform-apply (docs/rollback-runbook.md section 5)."
  } >"$WORK/drift.md"
  cat "$WORK/plan.txt"
  echo "::warning::Drift detected in $ENV: ${PLAN_LINE:-see plan}"
  exit 3
fi

if [ "$CMD" = plan ]; then
  cat "$WORK/plan.txt" # sensitive variables are redacted by Terraform; the account ID is masked by GitHub
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "digest=$DIGEST" >>"$GITHUB_OUTPUT"; fi
  if [ "$MODE" = destroy ]; then
    next="run **cleanup** with \`plan_digest = $DIGEST\` and \`confirm = destroy-$ENV\`, then approve the \`$ENV\` environment"
  else
    next="run **terraform-apply** with \`plan_digest = $DIGEST\`, then approve the \`$ENV\` environment"
  fi
  {
    echo
    echo "To apply exactly this plan: $next."
  } >>"$SUMMARY"
  exit 0
fi

# --- apply ---
[[ ${EXPECTED_DIGEST:-} =~ ^[0-9a-f]{64}$ ]] || { echo "::error::plan_digest must be 64 lowercase hex characters"; exit 2; }
if [ "$DIGEST" != "$EXPECTED_DIGEST" ]; then
  echo "::error::Refusing to apply: the plan changed since it was reviewed (code, variables or real infrastructure). Run terraform-plan again and review the new plan."
  echo "reviewed: $EXPECTED_DIGEST" >&2
  echo "now:      $DIGEST" >&2
  exit 1
fi
echo "Plan digest matches the reviewed plan. Applying ($MODE)."
terraform -chdir="$STACK" apply -input=false -no-color -lock-timeout=5m "$WORK/tfplan"

if [ "$MODE" = destroy ]; then
  # Verify, do not assume: the state must be empty and the environment's load balancer must be gone.
  left=$(terraform -chdir="$STACK" state list | grep -v '^data\.' | grep -v '\.data\.' || true)
  if [ -n "$left" ]; then
    echo "::error::cleanup incomplete, still in state:"
    echo "$left"
    exit 1
  fi
  if aws elbv2 describe-load-balancers --names "idp-$ENV" >/dev/null 2>&1; then
    echo "::error::cleanup incomplete: load balancer idp-$ENV still exists"
    exit 1
  fi
  {
    echo
    echo "### Cleanup verified"
    echo "- Terraform state of \`$ENV\` holds no resources."
    echo "- Load balancer \`idp-$ENV\` no longer exists."
    echo "- Kept (bootstrap): state bucket, CloudTrail, CI roles, ECR images, budget."
  } >>"$SUMMARY"
  echo "Cleanup of $ENV verified."
  exit 0
fi
{
  echo
  echo "### Outputs"
  echo '```'
  terraform -chdir="$STACK" output -no-color | grep -v -E '^(account_id|alert_topic_arn) '
  echo '```'
} >>"$SUMMARY"
