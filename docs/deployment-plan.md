# Deployment plan and roadmap

Nothing in this repository has been deployed. Every AWS-changing step below requires explicit
owner approval at the start of its phase. `terraform apply` and `terraform destroy` are never run
automatically.

## 1. Phase 0 — AWS environment assessment (2026-11-23)

### 1.0 Update: discovery completed by the owner (2026-11-23T02:45:24Z, AWS CloudShell us-east-2)

✅ Done. Results and their impact on Phase 3: [aws-discovery-2026-11-23.md](aws-discovery-2026-11-23.md).
In short: correct account; us-east-1 confirmed SCP-denied; the shared OIDC provider, AIOps bucket,
ECR repository and $30 budget are present; no leftover billable resources; month-to-date cost is
nothing above $0.01. **New findings:** no CloudTrail trail, and a second SCP denying at least
`iam:ListAccountAliases`.

### 1.1 Original result (build environment): **blocked — no usable AWS credentials**

| Check | Result |
|---|---|
| AWS CLI identity (`sts get-caller-identity`) | ❌ `InvalidClientTokenId`. The session's environment exposes only a placeholder access key, which AWS rejects. No real credentials were available, so **no AWS API call succeeded**. |
| Account ID, Region, Organizations, SCPs, OIDC provider, ECR, state buckets, ECS, quotas, costs, budgets | ⏸️ Not assessed (depends on the above) |

This was not worked around: the project rules require authorized credentials, and SigV4 request
signing cannot be delegated to a header-injecting proxy anyway.

### 1.2 What we know from the previous project (not assumed to apply here)

The AIOps project ran in an AWS Organizations member account where an SCP explicitly denied regional services in **us-east-1**, so it moved to **us-east-2**
([its ADR 0003](https://github.com/oteyami2001/AWS-Cloud-Operations-AI-Automation/blob/main/docs/adr/0003-region-us-east-2.md)).
That account already holds a GitHub OIDC provider (one per account) and `aiops-*` resources. If
the same account is reused, set `create_oidc_provider = false` and verify cleanup of the previous
project first.

### 1.3 Owner action: run the read-only discovery

`scripts/aws_discovery.sh` makes only Describe/List/Get calls (and one optional $0.01 Cost Explorer
call, skippable with `SKIP_COST_EXPLORER=1`). It records denials instead of failing, so SCP
restrictions show up as findings.

```bash
scripts/aws_discovery.sh us-east-2 us-east-1 > discovery-report.md
```

Review the report (it contains your account ID) and share the findings or the redacted report.
It answers: identity, account, default Region, Organizations membership, whether SCPs deny the
candidate Regions, existing OIDC provider / roles / state buckets / ECR repositories / ECS clusters,
NAT gateways and Elastic IPs already costing money, VPC / Fargate / ALB quotas, month-to-date cost,
existing budgets and CloudTrail trails.

### 1.4 Owner decisions

| # | Decision | Status |
|---|---|---|
| 1 | **Target AWS account** | ✅ **Decided 2026-11-23:** reuse the AIOps project's account and keep all of its resources ([ADR 0005](adr/0005-shared-account-with-aiops-project.md)) |
| 2 | **Target Region** | ✅ **us-east-2** (only approved Region in code; us-east-1 is SCP-denied in this account) |
| 3 | **Budgets** | ✅ account-wide: keep the existing `aiops-account-monthly` ($30) · ✅ project budget `idp-project-monthly` $25 (decided 2026-11-23) |
| 4 | **Alert e-mail** and **operator `/32`** | ✅ both provided, stored as GitHub environment secret/variable (never committed); the /32 must also be set on `dev-plan` ([dev-deployment-runbook.md §0](dev-deployment-runbook.md)) |
| 5 | **HTTPS for the demo?** | ❓ open. A Route 53 domain + ACM certificate removes exception SE-2 |
| 6 | **CloudTrail trail** (none exists) | ✅ **Decided 2026-11-23:** add a single-Region management-events trail in the bootstrap |
| 7 | **Where to run the bootstrap** | ✅ AWS CloudShell us-east-2 as the existing admin role (no local keys) |

Discovery is still required before Phase 3, now to **confirm** the inherited state: run
`scripts/aws_discovery.sh us-east-2 us-east-1`. Expected: the OIDC provider and `aiops-*` roles,
bucket, ECR repository and budget exist; no VPC, ALB, NAT or ECS cluster is left from AIOps;
us-east-1 calls are denied by the SCP.

## 2. Phase-by-phase roadmap

| Phase | Scope | AWS changes | Exit criteria (evidence) | Status |
|---|---|---|---|---|
| **0** Assessment | Repo inspection, read-only AWS discovery | None | Repo assessment ✅; AWS discovery report (owner-run) ✅ | ✅ (2026-11-23) |
| **1** Architecture and scaffolding | Docs, ADRs, FastAPI app, Dockerfile, manifest schema/policy/validator, catalog, Terraform interfaces + guardrail tests | None | `make check` green; container smoke test | ✅ (see portfolio-evidence.md) |
| **2** CI and security automation | `ci.yml` (all checks), TFLint config, Trivy fs + image gates, SHA-pinned actions, Dependabot, `main` ruleset + secret scanning + push protection ([github-settings.md](github-settings.md)), multi-platform provider lock files | None | Green CI on a PR ✅; zlib CVE closed by the runner build ✅; a deliberately insecure Terraform change fails on a PR 📋; `verify_github_settings.sh` passes ✅ | ✅ merged (PR #1) · 1 exit item open |
| **3** Bootstrap *(approved 2026-11-23)* | State bucket, CloudTrail trail, plan/apply/deploy/image-push roles (shared OIDC provider looked up), boundary, ECR, project budget ([bootstrap-runbook.md](bootstrap-runbook.md)); GitHub environments `dev-plan`, `dev`, `dev-deploy` (`scripts/configure_github_environments.sh`) | Yes (< $1/month) | Plan `28 to add`; `verify_bootstrap.sh` and `verify_github_settings.sh` all PASS | 🛠️✅ code + tests · ⏳ owner apply |
| **4** Dev infrastructure *(approval)* | network, load-balancer, ecs-cluster, ecs-service (once an image exists), observability; `terraform-plan`/`terraform-apply` with the reviewed-plan digest gate ([dev-deployment-runbook.md](dev-deployment-runbook.md)) | Yes (≈ $0.03/h while it exists) | Plan reviewed; apply digest = reviewed digest; ALB answers 503 from the /32 only; alarms + dashboard exist; re-plan shows no changes | ☁️ AWS-verified 2026-11-23 |
| **5** Delivery pipeline | `image-build.yml` (build, smoke, Trivy, push, digest, SBOM), `app-deploy.yml` (digest-pinned task definition, steady-state wait, report) | Image pushes, task definitions | Deploy by digest; an unapproved deploy is blocked (screenshot/API) | 🛠️✅ code + tests ([release-runbook.md](release-runbook.md)) · ⏳ owner runs |
| **6** Self-service | `platform/templates/python-service`, `scripts/new_service.py`, deploy-request issue form, catalog page | None | A new service created from the template passes CI unchanged | 📋 |
| **7** Operations and recovery | Circuit-breaker rollback test, rollback runbook drills, `drift-detection.yml`, `cleanup.yml`, dashboard | Temporary | Failing release auto-rolls back; manual drift detected and reported, not fixed; cleanup verified | 📋 |
| **8** Validation and portfolio | All 12 required scenarios with timestamps, diagrams, recruiter overview | Temporary | `portfolio-evidence.md` complete with real measurements only | 📋 |

## 3. Deployment commands (reference; Phase 3+)

```bash
# Phase 3 bootstrap (administrator, local state first)
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap plan -out=bootstrap.tfplan \
  -var aws_account_id=<ACCOUNT_ID> -var alert_email=<EMAIL> -var github_repository_id=<REPO_ID>
# region defaults to us-east-2; create_oidc_provider defaults to false (shared provider)
# The plan must show 0 changes to any aiops-* resource or to the OIDC provider.
# review, then (only after approval):
terraform -chdir=terraform/bootstrap apply bootstrap.tfplan
```

```bash
# Phase 4+ (normally via GitHub Actions; shown for clarity)
terraform -chdir=terraform/stack init -backend-config=../envs/dev/backend.hcl
terraform -chdir=terraform/stack plan -var-file=../envs/dev/terraform.tfvars -out=tfplan
```

## 4. Cleanup (Phase 7 automates this)

Workload resources (ALB, ECS service and cluster, VPC, alarms) are destroyed after each demo
through an approved destroy plan. Bootstrap resources (state bucket, OIDC roles, ECR, budget) cost
well under $1/month and are retained between demos. Cleanup never touches `aiops-*` resources or
the shared OIDC provider; the post-cleanup check filters on `Project=idp`.
