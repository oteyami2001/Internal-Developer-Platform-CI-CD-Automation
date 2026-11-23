# Cost model

> ⚠️ **Unverified planning estimates.** The unit prices below are on-demand list prices for
> **us-east-2** (Linux/x86) as known when this was written (2026-11-23). They were **not**
> retrieved from the AWS Price List API or Pricing Calculator during Phase 1, because no AWS access
> was available. Re-price with the [AWS Pricing Calculator](https://calculator.aws/) for the
> confirmed Region **before Phase 3/4 approval** and update this file. Taxes and support plans are excluded.

## 1. Unit prices used (verify)

| Item | Assumed unit price | Notes |
|---|---|---|
| ALB | $0.0225 per ALB-hour | Charged for every partial hour while it exists |
| ALB LCU | $0.008 per LCU-hour | Demo traffic is tiny; health checks alone use a fraction of an LCU |
| Fargate vCPU | $0.04048 per vCPU-hour | Per-second billing, 1-minute minimum |
| Fargate memory | $0.004445 per GB-hour | |
| Public IPv4 address | $0.005 per IP-hour | ALB uses 1 per AZ (2), plus 1 per public Fargate task |
| CloudWatch Logs | $0.50 per GB ingested; $0.03 per GB-month stored | Health-check logs suppressed at INFO to cut ingest |
| CloudWatch alarms | $0.10 per standard alarm-month | ~6 alarms planned |
| CloudWatch dashboard | $3.00 per dashboard-month beyond the free 3 | Likely free |
| ECR storage | $0.10 per GB-month | Sample image ≈ 50 MB gzip-compressed, 208 MB uncompressed (measured locally) |
| S3 (state) | < $0.05/month | KB-sized objects, versioned |
| AWS Budgets | First budgets free (verify current free allowance) | Notifications only |
| NAT Gateway (avoided) | ~$0.045/hour + $0.045/GB | ≈ $33/month, so it is **excluded** from the MVP |
| EKS control plane (avoided) | $0.10/hour | ≈ $73/month; see ADR 0001 |

## 2. Scenarios

Workload: 1 service, 1 task at 0.25 vCPU / 0.5 GB, 1 ALB across 2 AZs, no NAT Gateway.

**Task cost per hour** = 0.25 × 0.04048 + 0.5 × 0.004445 = **$0.01234**

| Scenario | Calculation | Estimate |
|---|---|---|
| **Offline development and CI** | Local Docker + GitHub-hosted runners (free for public repos) | **$0.00** AWS |
| **Bootstrap only (always-on)** | S3 state + ECR storage + budget + IAM (free) | **< $0.20/month** |
| **Short demo (3 hours)** | ALB 3 × 0.0225 = 0.068 · Fargate 3 × 0.0123 = 0.037 · 3 IPv4 × 3 h × 0.005 = 0.045 · LCU ≈ 0.01–0.03 · CloudWatch ≈ 0.01 | **≈ $0.17–$0.25** (partial hours round up for ALB) |
| **Demo with a rolling deploy + rollback test** | Adds a second task for ~10 min per deployment | **+ < $0.01** per deployment |
| **Continuous MVP (730 h/month)** | ALB 16.43 · LCU 0.5–5.8 · Fargate 9.01 · IPv4 (3) 10.95 · alarms 0.60 · logs ≈ 0.5–1 · ECR/S3 ≈ 0.2 | **≈ $38–$45/month** |
| Continuous prod-reference (2 tasks, private subnets, NAT ×1, HTTPS) | Above + 1 task (~9) + NAT (~33) − task public IP (~3.65) | **≈ $75–$90/month**, which is why prod is Terraform-only for now |

The Phase 1 prompt's preliminary ranges ($0.15–$0.60 per demo, $35–$65 per month continuous)
are consistent with these estimates.

## 3. Budget recommendation

- **Account budget: the existing `aiops-account-monthly` ($30/month, account-wide)** from the AIOps
  project is kept ([ADR 0005](adr/0005-shared-account-with-aiops-project.md)). It already counts
  this project's spend, so no second account-wide budget is created.
- **Project budget: $25/month** on the `Project=idp` tag (bootstrap `project_monthly_budget_usd`;
  requires activating `Project` as a cost-allocation tag, which can take up to 24 h).
- Inherited baseline: the AIOps bootstrap costs about $0.01/month and stays.
- A continuously running MVP (~$38–$45) **would exceed** both the $25 project budget and the $30 account budget. The operating model is
  **deploy for a demo, then run approved cleanup**.
- **Budgets do not stop spending.** They notify. The cost control is `cleanup.yml` (Phase 7) plus
  the discipline of tearing down after each demo. Budget data also lags by up to ~8–24 hours.

## 4. Cost guardrails in code

| Guardrail | Where | Status |
|---|---|---|
| Fargate size capped (dev ≤ 0.5 vCPU / 1 GB) and task count capped (dev ≤ 2) | `platform/policy/platform-policy.yaml` | ✅ |
| Non-prod log retention ≤ 30 days (dev default 7) | `terraform/stack/variables.tf` | ✅ |
| Budget limit bounded 1–200 USD | Stack + `budgets` module | ✅ |
| No NAT Gateway, Container Insights off in dev, REJECT-only flow logs | Module defaults | 🛠️ interface · 📋 resources |
| Health-check request logs suppressed at INFO | `apps/sample-api/app/main.py` | ✅ |
| Post-cleanup check: no ALB, tasks, EIPs or NAT left | `cleanup.yml` + `scripts/aws_discovery.sh` cost checks | 📋 Phase 7 |
