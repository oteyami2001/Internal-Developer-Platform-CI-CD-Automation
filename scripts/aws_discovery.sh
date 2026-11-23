#!/usr/bin/env bash
# Phase 0 AWS environment discovery - READ-ONLY.
#
# Every call below is a Describe/List/Get API. Nothing is created, modified or deleted. A denied
# call is recorded as DENIED (often itself a finding, e.g. an SCP) and the script continues.
#
# Usage:  scripts/aws_discovery.sh <region> [<region> ...]   e.g. scripts/aws_discovery.sh us-east-2 us-east-1
# Output: a Markdown report on stdout. Review it before sharing: it contains your account ID.
#
# Cost note: the Cost Explorer call (ce:GetCostAndUsage) is billed at $0.01 per request; it runs
# once and is skipped with SKIP_COST_EXPLORER=1.
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <region> [<region> ...]" >&2
  exit 2
fi
command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 2; }

run() { # run <label> <aws args...>
  local label=$1; shift
  local out
  if out=$(aws "$@" --output json 2>&1); then
    printf -- '- **%s**: OK\n\n```json\n%s\n```\n\n' "$label" "$(printf '%s' "$out" | head -c 4000)"
  else
    local reason
    reason=$(printf '%s' "$out" | grep -oE '(AccessDenied[A-Za-z]*|UnauthorizedOperation|explicit deny[^.]*|AWSOrganizationsNotInUse[A-Za-z]*|[A-Za-z]+Exception)' | head -1)
    printf -- '- **%s**: DENIED/ERROR (%s)\n\n```\n%s\n```\n\n' "$label" "${reason:-see output}" "$(printf '%s' "$out" | head -c 1500)"
  fi
}

echo "# AWS discovery report"
echo
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/aws_discovery.sh (read-only)"
echo
echo "## Identity and organization"
run "Caller identity" sts get-caller-identity
run "Configured default region" configure list
run "Organization membership" organizations describe-organization
run "Account aliases" iam list-account-aliases
run "GitHub OIDC providers" iam list-open-id-connect-providers
run "Existing project roles (idp-*)" iam list-roles --query "Roles[?starts_with(RoleName, 'idp-')].RoleName"
run "Terraform state buckets" s3api list-buckets --query "Buckets[?contains(Name, 'tfstate')].Name"
run "CloudTrail trails" cloudtrail describe-trails --query "trailList[].{Name:Name,MultiRegion:IsMultiRegionTrail,Home:HomeRegion}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -n "$ACCOUNT_ID" ]; then
  run "Budgets" budgets describe-budgets --account-id "$ACCOUNT_ID" --query "Budgets[].{Name:BudgetName,Limit:BudgetLimit,Type:BudgetType}"
fi

if [ "${SKIP_COST_EXPLORER:-0}" != "1" ]; then
  START=$(date -u +%Y-%m-01)
  END=$(date -u -d tomorrow +%Y-%m-%d 2>/dev/null || date -u -v+1d +%Y-%m-%d)
  run "Month-to-date cost by service (Cost Explorer, \$0.01)" ce get-cost-and-usage \
    --time-period "Start=$START,End=$END" --granularity MONTHLY --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query "ResultsByTime[0].Groups[?to_number(Metrics.UnblendedCost.Amount) > \`0.01\`].{Service:Keys[0],USD:Metrics.UnblendedCost.Amount}"
fi

for REGION in "$@"; do
  echo "## Region $REGION"
  echo
  echo "Regional read calls. An explicit deny from a service control policy here means the region"
  echo "cannot be used for this project (as happened with us-east-1 in the previous project)."
  echo
  run "Availability Zones" ec2 describe-availability-zones --region "$REGION" --query "AvailabilityZones[].ZoneName"
  run "VPCs" ec2 describe-vpcs --region "$REGION" --query "Vpcs[].{Id:VpcId,Cidr:CidrBlock,Default:IsDefault}"
  run "ECR repositories" ecr describe-repositories --region "$REGION" --query "repositories[].repositoryName"
  run "ECS clusters" ecs list-clusters --region "$REGION"
  run "ECS account settings" ecs list-account-settings --effective-settings --region "$REGION" --query "settings[].{Name:name,Value:value}"
  run "Load balancers" elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[].LoadBalancerName"
  run "NAT gateways (cost check)" ec2 describe-nat-gateways --region "$REGION" --query "NatGateways[?State=='available'].NatGatewayId"
  run "Elastic IPs (cost check)" ec2 describe-addresses --region "$REGION" --query "Addresses[].PublicIp"
  run "Quota: VPCs per Region" service-quotas get-service-quota --region "$REGION" --service-code vpc --quota-code L-F678F1CE --query "Quota.Value"
  run "Quota: Fargate On-Demand vCPU" service-quotas get-service-quota --region "$REGION" --service-code fargate --quota-code L-3032A538 --query "Quota.Value"
  run "Quota: ALBs per Region" service-quotas get-service-quota --region "$REGION" --service-code elasticloadbalancing --quota-code L-53DA6B97 --query "Quota.Value"
  run "Secrets Manager secrets (names only)" secretsmanager list-secrets --region "$REGION" --query "SecretList[].Name"
done
