#!/usr/bin/env bash
# Terraform plan/apply for one environment, as run by terraform-plan.yml and terraform-apply.yml.
# Both workflows call THIS script, so the apply re-creates the plan exactly the way the reviewed
# plan was created.
#
#   tf_ci.sh plan  <env>   plan, print a reviewable summary and the PLAN DIGEST
#   tf_ci.sh apply <env>   re-plan; refuse unless the digest equals $EXPECTED_DIGEST; apply that plan
#
# Why a digest instead of uploading the plan file: this repository is public, and a plan file
# contains the plaintext values of every variable (alert e-mail, operator IP) and state data.
# The digest is a SHA-256 over every planned change (address, action, after-values). Any change in
# code, variables or real infrastructure between review and apply produces a different digest, and
# the apply stops. Nothing sensitive is stored as an artifact.
#
# Required environment (set by the workflow from GitHub environment variables/secrets):
#   AWS_ROLE_ARN, AWS_REGION, TF_STATE_BUCKET, ALLOWED_INGRESS_CIDR, TF_VAR_alert_email
# Optional: SERVICE_IMAGE (digest-pinned image; empty = infrastructure only), EXPECTED_DIGEST (apply)
set -euo pipefail

CMD=${1:?usage: tf_ci.sh plan|apply <env>}
ENV=${2:?usage: tf_ci.sh plan|apply <env>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STACK="$ROOT/terraform/stack"
WORK=${RUNNER_TEMP:-$(mktemp -d)}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}

case "$ENV" in dev | staging | prod) ;; *) echo "unknown environment: $ENV" >&2; exit 2 ;; esac
case "$CMD" in plan | apply) ;; *) echo "unknown command: $CMD" >&2; exit 2 ;; esac
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
if [ -n "${SERVICE_IMAGE:-}" ]; then export TF_VAR_service_image=$SERVICE_IMAGE; fi
export TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1

# --- Service settings from the validated manifest (never hand-written) ---
python "$ROOT/scripts/validate_service.py" --render "$ENV" "$ROOT/apps/sample-api/service.yaml" \
  | jq '{service: .}' >"$WORK/service.tfvars.json"

terraform -chdir="$STACK" init -input=false -lockfile=readonly -no-color \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=envs/$ENV/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true" >/dev/null

set +e
terraform -chdir="$STACK" plan -input=false -no-color -lock-timeout=5m -detailed-exitcode \
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
# Canonical, order-independent description of every change; hashed, never published in clear.
DIGEST=$(jq -S -c '[.resource_changes[]? | select(.change.actions != ["no-op"])
  | {address, actions: .change.actions, after: .change.after, after_unknown: .change.after_unknown}]
  | sort_by(.address)' "$WORK/plan.json" | sha256sum | cut -d' ' -f1)
PLAN_LINE=$(grep -E '^(Plan:|No changes\.)' "$WORK/plan.txt" | head -1 || true)

{
  echo "## terraform $CMD: $ENV"
  echo
  echo "- Commit: \`${GITHUB_SHA:-local}\`"
  echo "- Result: **${PLAN_LINE:-see log}**"
  echo "- Plan digest: \`$DIGEST\`"
  echo
  echo "| Action | Resource |"
  echo "|---|---|"
  jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "| \(.change.actions | join("/")) | `\(.address)` |"' "$WORK/plan.json"
} >>"$SUMMARY"

if [ "$CMD" = plan ]; then
  cat "$WORK/plan.txt" # sensitive variables are redacted by Terraform; the account ID is masked by GitHub
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "digest=$DIGEST" >>"$GITHUB_OUTPUT"; fi
  {
    echo
    echo "To apply exactly this plan: run **terraform-apply** with \`plan_digest = $DIGEST\`, then approve the \`$ENV\` environment."
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
echo "Plan digest matches the reviewed plan. Applying."
terraform -chdir="$STACK" apply -input=false -no-color -lock-timeout=5m "$WORK/tfplan"
{
  echo
  echo "### Outputs"
  echo '```'
  terraform -chdir="$STACK" output -no-color | grep -v -E '^(account_id|alert_topic_arn) '
  echo '```'
} >>"$SUMMARY"
