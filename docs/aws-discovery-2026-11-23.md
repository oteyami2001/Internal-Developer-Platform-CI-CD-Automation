# AWS discovery — 2026-11-23

Source: `scripts/aws_discovery.sh us-east-2 us-east-1`, run by the owner in **AWS CloudShell
(us-east-2)** at **2026-11-23T02:45:24Z**. Read-only: Describe/List/Get calls plus one Cost
Explorer request. Identifiers are redacted here: account ID, organization and management-account
details, SCP IDs. The raw report stays with the owner and is git-ignored (`discovery-report*.md`).

## Identity and organization

| Check | Result | Assessment |
|---|---|---|
| Caller | `assumed-role/AccountFullAccessRole/…` in the AIOps account (via CloudShell's container role) | ✅ Correct account (ADR 0005). Admin role: used for the Phase 3 bootstrap only, from CloudShell, with no local keys |
| Organizations | Member of an AWS Organization, feature set ALL, **SCPs enabled** | As expected |
| `iam:ListAccountAliases` | ❌ **explicit deny by an SCP** (a *second* SCP, distinct from the regional one) | ⚠️ **New finding.** Its full scope cannot be read from a member account. The AIOps bootstrap created IAM roles successfully on 2026-11-22, so `iam:CreateRole`/`PutRolePolicy` were allowed then. Phase 3 will surface any further IAM deny at plan/apply time without partial damage (see below) |
| GitHub OIDC provider | ✅ `token.actions.githubusercontent.com` exists | Shared; looked up, never managed (`create_oidc_provider = false`) |
| `idp-*` IAM roles | none | ✅ No name collisions |
| Terraform state buckets | only `aiops-tfstate-<account>-us-east-2` | ✅ `idp-tfstate-…` is free |
| **CloudTrail trails** | **none** (`[]`, also no organization trail visible) | ⚠️ **Audit gap.** Only CloudTrail *Event history* exists (90 days of management events, free). See "Decisions" |
| Budgets | `aiops-account-monthly`, 30 USD, COST | ✅ Kept as the account guardrail |
| Month-to-date cost | no service above $0.01 | ✅ Nothing billable is running |

## us-east-2 (target Region)

| Check | Result | Assessment |
|---|---|---|
| Availability Zones | us-east-2a, 2b, 2c | ✅ 2-AZ ALB possible |
| VPCs | only the default VPC (172.31.0.0/16) | ✅ AIOps VPC destroyed. 1 of the 5-VPC quota used. `idp` uses `10.40.0.0/20` (no overlap) |
| ECR | `aiops-sample-app` | ✅ Retained AIOps repo; `idp/*` will not collide |
| ECS clusters / load balancers / NAT gateways / Elastic IPs / Secrets | none | ✅ No leftover billable resources |
| ECS account settings | `tagResourceAuthorization: on`, `containerInsights: disabled`, `fargateTaskRetirementWaitPeriod: 7` | `tagResourceAuthorization` means tagging at creation needs `ecs:TagResource`: the Phase 3 apply role must include it |
| Quotas | VPCs 5, ALBs 50, **Fargate On-Demand vCPU 12** | ✅ Ample (MVP needs 0.25–0.5 vCPU) |

## us-east-1

Every regional call (EC2, ECR, ECS, ELB, Secrets Manager) returned an **explicit deny from the
regional SCP**. Service Quotas reads were allowed. This confirms ADR 0005: **us-east-2 only**.

## Impact on Phase 3

1. **Run the bootstrap from CloudShell (us-east-2)** as `AccountFullAccessRole`: no local AWS keys.
   Install the pinned Terraform binary in `~/bin` (CloudShell home persists). Migrate the bootstrap
   state to the new S3 bucket immediately after the first apply.
2. **Apply role permissions** must include `ecs:TagResource` (tag-on-create authorization is on).
3. **Unknown IAM SCP:** the bootstrap is ordered so IAM resources come first in a small, reviewable
   plan; an SCP deny fails the apply before any billable resource exists.
4. **CloudTrail:** decide between Event history only (free, 90 days) and a single-Region trail
   (management events, first copy free; only S3 storage of a few cents/month). Recommendation: the trail,
   because deployment evidence older than 90 days is part of the portfolio.
