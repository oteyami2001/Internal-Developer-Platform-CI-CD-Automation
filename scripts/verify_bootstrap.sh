#!/usr/bin/env bash
# Verify the Phase 3 bootstrap in AWS - READ-ONLY (Describe/Get/List only).
#
# Run in AWS CloudShell (us-east-2) after `terraform apply`. Checks the live resources, not the
# Terraform plan: what AWS reports is the evidence for docs/portfolio-evidence.md.
#
# Usage:  scripts/verify_bootstrap.sh
# Needs:  aws CLI v2 + jq (both preinstalled in CloudShell)
set -uo pipefail

PROJECT=idp
REGION=${AWS_REGION:-us-east-2}
OIDC_PREFIX="repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { # expect <label> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (is: ${2:-<none>}, expected: $3)"; fi
}

ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || { echo "no AWS credentials" >&2; exit 2; }
echo "# Bootstrap verification ($(date -u +%Y-%m-%dT%H:%M:%SZ), Region $REGION)"

# --- State bucket ---
B="$PROJECT-tfstate-$ACCOUNT-$REGION"
expect "state bucket versioning" "$(aws s3api get-bucket-versioning --bucket "$B" --query Status --output text 2>/dev/null)" Enabled
expect "state bucket encryption" "$(aws s3api get-bucket-encryption --bucket "$B" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null)" aws:kms
expect "state bucket public access fully blocked" "$(aws s3api get-public-access-block --bucket "$B" --output json 2>/dev/null | jq -r '[.PublicAccessBlockConfiguration[]] | all')" true
expect "state bucket denies non-TLS" "$(aws s3api get-bucket-policy --bucket "$B" --query Policy --output text 2>/dev/null | jq -r 'any(.Statement[]; .Effect == "Deny" and .Condition.Bool["aws:SecureTransport"] == "false")')" true

# --- CloudTrail ---
T="$PROJECT-management-events"
expect "CloudTrail trail is logging" "$(aws cloudtrail get-trail-status --name "$T" --query IsLogging --output text 2>/dev/null)" True
expect "CloudTrail log file validation" "$(aws cloudtrail describe-trails --trail-name-list "$T" --query 'trailList[0].LogFileValidationEnabled' --output text 2>/dev/null)" True
last=$(aws cloudtrail get-trail-status --name "$T" --query LatestDeliveryTime --output text 2>/dev/null)
printf 'INFO  CloudTrail latest delivery: %s (first delivery can take ~15 minutes)\n' "${last:-none yet}"

# --- GitHub OIDC roles: exact subjects ---
for pair in "dev-github-plan:environment:dev-plan" "dev-github-apply:environment:dev" "dev-github-deploy:environment:dev-deploy" "github-image-push:ref:refs/heads/main"; do
  role="$PROJECT-${pair%%:*}"
  want="$OIDC_PREFIX:${pair#*:}"
  doc=$(aws iam get-role --role-name "$role" --query Role.AssumeRolePolicyDocument --output json 2>/dev/null)
  [ -n "$doc" ] || doc='{}'
  expect "$role trusts exactly $want" "$(jq -r '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] // empty' <<<"$doc")" "$want"
  expect "$role audience is sts.amazonaws.com" "$(jq -r '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] // empty' <<<"$doc")" sts.amazonaws.com
done

# --- Permissions boundary ---
expect "dev workload boundary exists" "$(aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT:policy/$PROJECT-dev-workload-boundary" --query Policy.PolicyName --output text 2>/dev/null)" "$PROJECT-dev-workload-boundary"

# --- ECR ---
expect "ECR idp/sample-api tags immutable" "$(aws ecr describe-repositories --repository-names "$PROJECT/sample-api" --query 'repositories[0].imageTagMutability' --output text 2>/dev/null)" IMMUTABLE
expect "ECR idp/sample-api scan on push" "$(aws ecr describe-repositories --repository-names "$PROJECT/sample-api" --query 'repositories[0].imageScanningConfiguration.scanOnPush' --output text 2>/dev/null)" True

# --- Budget ---
expect "project budget idp-project-monthly" "$(aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$PROJECT-project-monthly" --query 'Budget.BudgetLimit.Amount' --output text 2>/dev/null | cut -d. -f1)" 25

# --- Shared-account safety (ADR 0005): the AIOps bootstrap is still intact ---
expect "shared GitHub OIDC provider still present" "$(aws iam list-open-id-connect-providers --query "length(OpenIDConnectProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')])" --output text)" 1
expect "AIOps budget untouched" "$(aws budgets describe-budget --account-id "$ACCOUNT" --budget-name aiops-account-monthly --query 'Budget.BudgetName' --output text 2>/dev/null)" aiops-account-monthly

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: $fails check(s) failed"; fi
exit $(( fails > 0 ))
