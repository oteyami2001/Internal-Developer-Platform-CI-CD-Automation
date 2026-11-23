#!/usr/bin/env bash
# Create/update the GitHub deployment environments and the settings the AWS workflows read.
# WRITES repository settings: run it yourself, signed in to gh as the repository owner
# (in a Codespace: `unset GITHUB_TOKEN && gh auth login` first). Idempotent: safe to re-run.
#
#   environment   required reviewer   deployment branches   used by (OIDC role it unlocks)
#   -----------   -----------------   -------------------   ------------------------------------------
#   dev-plan      -                   main only             terraform-plan, drift-detection (plan role)
#   dev           owner               main only             terraform-apply, cleanup (apply role)
#   dev-deploy    owner               main only             app-deploy (deploy role)
#
# Each AWS role trusts exactly one of these environments (or refs/heads/main for image push), so
# a job that is not in the approved environment cannot obtain AWS credentials at all.
#
# Usage:  [ALLOWED_INGRESS_CIDR=x.x.x.x/32] scripts/configure_github_environments.sh <aws_account_id> <alert_email> [owner/repo]
#         ALLOWED_INGRESS_CIDR (the operator's /32 for the HTTP demo listener) is set on dev-plan and
#         dev when provided: both the plan and the apply job need it.
# Then:   scripts/verify_github_settings.sh   (checks reviewers and branch policies via the API)
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <aws_account_id> <alert_email> [owner/repo]" >&2
  exit 2
fi
ACCOUNT_ID=$1
ALERT_EMAIL=$2
REPO=${3:-oteyami2001/Internal-Developer-Platform-CI-CD-Automation}
PROJECT=idp
REGION=us-east-2

[[ $ACCOUNT_ID =~ ^[0-9]{12}$ ]] || { echo "account id must be 12 digits" >&2; exit 2; }
[[ $ALERT_EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]] || { echo "invalid e-mail" >&2; exit 2; }
command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 2; }
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "GITHUB_TOKEN is set (e.g. a Codespace token) and cannot manage environments." >&2
  echo "Run: unset GITHUB_TOKEN && gh auth login   then re-run this script." >&2
  exit 2
fi

OWNER=${REPO%%/*}
REVIEWER_ID=$(gh api "users/$OWNER" --jq .id)
ROLE="arn:aws:iam::$ACCOUNT_ID:role/$PROJECT"
STATE_BUCKET="$PROJECT-tfstate-$ACCOUNT_ID-$REGION"

configure_env() { # configure_env <name> <needs_reviewer: true|false>
  local env=$1 reviewer=$2 body
  if [ "$reviewer" = true ]; then
    body=$(printf '{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$REVIEWER_ID")
  else
    body='{"wait_timer":0,"reviewers":[],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  fi
  gh api -X PUT "repos/$REPO/environments/$env" --input - <<<"$body" >/dev/null
  # Allow deployments from main only (create the policy once).
  if ! gh api "repos/$REPO/environments/$env/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main; then
    gh api -X POST "repos/$REPO/environments/$env/deployment-branch-policies" -f name=main -f type=branch >/dev/null
  fi
  echo "environment $env: reviewer=$reviewer, branches=main"
}

configure_env dev-plan false
configure_env dev true
configure_env dev-deploy true

# Variables: only values that identify nobody. GitHub prints variables in clear text in the logs of
# a PUBLIC repository (every step echoes the job's env), so anything containing the account ID,
# the operator's IP or the e-mail is a SECRET: GitHub masks secrets from the first log line.
gh variable set AWS_REGION --repo "$REPO" --body "$REGION"

# Secrets. Role ARNs follow the bootstrap's fixed naming scheme (they contain the account ID).
gh secret set TF_STATE_BUCKET         --repo "$REPO" --body "$STATE_BUCKET"
gh secret set AWS_IMAGE_PUSH_ROLE_ARN --repo "$REPO" --body "$ROLE-github-image-push"
gh secret set AWS_ROLE_ARN --repo "$REPO" --env dev-plan   --body "$ROLE-dev-github-plan"
gh secret set AWS_ROLE_ARN --repo "$REPO" --env dev        --body "$ROLE-dev-github-apply"
gh secret set AWS_ROLE_ARN --repo "$REPO" --env dev-deploy --body "$ROLE-dev-github-deploy"
gh secret set ALERT_EMAIL  --repo "$REPO" --env dev-plan   --body "$ALERT_EMAIL"
gh secret set ALERT_EMAIL  --repo "$REPO" --env dev        --body "$ALERT_EMAIL"

if [ -n "${ALLOWED_INGRESS_CIDR:-}" ]; then
  [[ $ALLOWED_INGRESS_CIDR =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || { echo "ALLOWED_INGRESS_CIDR must be a /32" >&2; exit 2; }
  gh secret set ALLOWED_INGRESS_CIDR --repo "$REPO" --env dev-plan --body "$ALLOWED_INGRESS_CIDR"
  gh secret set ALLOWED_INGRESS_CIDR --repo "$REPO" --env dev      --body "$ALLOWED_INGRESS_CIDR"
fi

# Remove the clear-text VARIABLES that earlier versions of this script created (now secrets).
delete_var() { gh variable delete "$1" --repo "$REPO" "${@:2}" >/dev/null 2>&1 && echo "removed variable $1 ${*:2}" || true; }
delete_var TF_STATE_BUCKET
delete_var AWS_IMAGE_PUSH_ROLE_ARN
for env in dev-plan dev dev-deploy; do
  delete_var AWS_ROLE_ARN --env "$env"
  delete_var ALLOWED_INGRESS_CIDR --env "$env"
done

echo "done. Verify with: scripts/verify_github_settings.sh $REPO"
