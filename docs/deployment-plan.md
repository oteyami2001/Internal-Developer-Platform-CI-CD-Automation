# Deployment plan and roadmap

Nothing in this repository has been deployed. Every AWS-changing step below requires explicit
owner approval at the start of its phase. `terraform apply` and `terraform destroy` are never run
automatically.

## 1. Phase 0 — AWS environment assessment (2026-11-23)

### 1.1 Result: **blocked — no usable AWS credentials in the build environment**

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
| 3 | **Budgets** | ✅ account-wide: keep the existing `aiops-account-monthly` ($30) · ❓ confirm the project budget `idp` ($25, Project tag) |
| 4 | **Alert e-mail** and **operator `/32`** | ❓ open (set as GitHub environment variables, never committed) |
| 5 | **HTTPS for the demo?** | ❓ open. A Route 53 domain + ACM certificate removes exception SE-2 |

Discovery is still required before Phase 3, now to **confirm** the inherited state: run
`scripts/aws_discovery.sh us-east-2 us-east-1`. Expected: the OIDC provider and `aiops-*` roles,
bucket, ECR repository and budget exist; no VPC, ALB, NAT or ECS cluster is left from AIOps;
us-east-1 calls are denied by the SCP.

## 2. Phase-by-phase roadmap

| Phase | Scope | AWS changes | Exit criteria (evidence) | Status |
|---|---|---|---|---|
| **0** Assessment | Repo inspection, read-only AWS discovery | None | Repo assessment ✅; AWS discovery report (owner-run) | ⚠️ repo done, AWS blocked |
| **1** Architecture and scaffolding | Docs, ADRs, FastAPI app, Dockerfile, manifest schema/policy/validator, catalog, Terraform interfaces + guardrail tests | None | `make check` green; container smoke test | ✅ (see portfolio-evidence.md) |
| **2** CI and security automation | `ci.yml` (all checks), TFLint config, Trivy fs + image gates, SHA-pinned actions, Dependabot, branch protection + CODEOWNERS enforcement, secret scanning + push protection, multi-platform provider lock file | None | Green CI on a PR; a deliberately insecure Terraform PR fails; zlib CVE closed by rebuilding on a runner | 📋 |
| **3** Bootstrap *(approval)* | State bucket, plan/apply/image-push/deploy roles (existing OIDC provider looked up, not created), boundary, ECR, project budget; GitHub environments `dev-plan`, `dev`, `dev-deploy` with required reviewers **verified via API** | Yes (≈ $0.20/month) | `terraform apply` output + IAM trust policies + environment protection API output | 📋 |
| **4** Dev infrastructure *(approval)* | network, load-balancer, ecs-cluster, ecs-service, observability, budgets via `terraform-plan`/`terraform-apply` | Yes (only while deployed) | Reviewed plan hash = applied plan hash; ALB serves `/health`; alarms exist | 📋 |
| **5** Delivery pipeline | `image-build.yml` (build, smoke, Trivy, push, digest, SBOM), `app-deploy.yml` (digest-pinned task definition, steady-state wait, report) | Image pushes, task definitions | Deploy by digest; an unapproved deploy is blocked (screenshot/API) | 📋 |
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
