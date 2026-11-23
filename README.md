# Internal Developer Platform & CI/CD Automation

A self-service **Internal Developer Platform (IDP) on AWS**. Developers describe a service in a
small, validated manifest and ship it through pull requests and approval-gated pipelines to
**Amazon ECS Fargate**, without AWS credentials and without being able to request IAM,
networking or arbitrary AWS resources.

**Stack:** AWS (ECS Fargate, ECR, ALB, VPC, IAM, CloudWatch, SNS, Budgets) · Terraform · GitHub
Actions + OIDC · Python 3.13/FastAPI · Docker · pytest · Ruff · Bandit · Checkov · TFLint · Trivy

> **Project status: Phase 3 (bootstrap) implemented and tested offline, in review. Nothing is deployed to AWS yet.**
> Legend: 📋 Planned · 🛠️ Implemented · ✅ Tested offline · ☁️ AWS-verified.
> Evidence: [docs/portfolio-evidence.md](docs/portfolio-evidence.md).
> Target: the AIOps project's AWS account in us-east-2, shared with that project's retained
> resources ([ADR 0005](docs/adr/0005-shared-account-with-aiops-project.md)).

## What works today

| Capability | Status |
|---|---|
| Sample FastAPI service: `/health`, `/ready`, `/version`, optional `/metrics`, JSON logs, graceful shutdown | 🛠️✅ 27 tests; hardened container smoke test |
| Multi-stage, digest-pinned, non-root (UID 10001), read-only-FS-compatible image | 🛠️✅ Checkov 85/85 |
| Service manifest: JSON Schema + platform policy + validator (rejects IAM/region/SG fields, secrets in env vars, oversize tasks, duplicate YAML keys…) | 🛠️✅ 51 tests |
| Generated service catalog with staleness check | 🛠️✅ |
| Terraform: single environment stack + dev/staging/prod data, account and region guards (us-east-2 only), ingress/HTTPS/retention/budget validation | 🛠️✅ 15 `terraform test` runs (mocked AWS) |
| Bootstrap (Phase 3): state bucket, CloudTrail, 4 OIDC roles, permissions boundary, ECR, budget; modules `iam-oidc`, `security`, `ecr`, `budgets` implemented | 🛠️✅ 23 `terraform test` runs + 10/10 mutations caught · ⏳ owner applies via [bootstrap-runbook.md](docs/bootstrap-runbook.md) |
| Remaining module interfaces (network, load-balancer, ecs-cluster, ecs-service, observability) | 🛠️✅ 7 ecs-service contract tests · 📋 resources in Phase 4 |
| `ci.yml`: pytest, Ruff, Bandit, manifests, catalog, Terraform fmt/validate/test/env data, TFLint, Checkov (IaC, Dockerfile, Actions, secrets), Trivy (repo + image), actionlint, zizmor, shellcheck; one `ci-ok` gate | ✅ green on GitHub ([PR #1](https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/pull/1)) |
| Workflow security rules as tests (SHA pins, least privilege, no OIDC in CI, no `pull_request_target`, no expression injection) | 🛠️✅ 23 tests |
| Deployment workflows, OIDC roles, ECR, ECS deployment, monitoring, rollback, drift, cleanup | 📋 Phases 3–7 |

## Architecture

```mermaid
flowchart LR
  dev([Developer]) -->|PR: code + service.yaml| gh[GitHub]
  gh --> ci[CI: tests, SAST, manifest, Terraform, scans<br/>no AWS credentials]
  gh -->|main + approval| oidc[GitHub OIDC -> short-lived IAM roles]
  oidc --> tf[Terraform: VPC, ALB, ECS, CloudWatch]
  oidc --> ecr[(ECR, immutable)]
  ecr -->|image@sha256| ecs[ECS Fargate task]
  user([Operator /32]) --> alb[ALB] --> ecs
  ecs --> cw[CloudWatch -> SNS]
```

Details: [docs/architecture.md](docs/architecture.md) (topology, environments, Terraform module
plan, workflow plan) · [diagrams/architecture.mmd](diagrams/architecture.mmd).

## Repository layout

```text
apps/sample-api/          FastAPI reference workload (app, tests, Dockerfile, service.yaml)
platform/schemas/         service.schema.json - the developer contract
platform/policy/          platform-policy.yaml - platform-owned guardrails
platform/catalog/         services.yaml - GENERATED service catalog
scripts/                  validate_service.py, generate_catalog.py, aws_discovery.sh (read-only)
terraform/bootstrap/      account foundation (state, OIDC roles, ECR, budget) - Phase 3
terraform/stack/          the single environment root module (+ guardrail tests)
terraform/envs/<env>/     per-environment data: terraform.tfvars, backend.hcl.example
terraform/modules/        network, load-balancer, ecs-cluster, ecs-service, ecr, iam-oidc,
                          security, observability, budgets
tests/platform/           manifest/policy/catalog tests
docs/                     architecture, security, threat model, cost, runbooks, evidence, ADRs
```

## Quick start (offline, no AWS)

```bash
make install
```

```bash
make check
```

```bash
make image smoke
```

`make help` lists every target. `make check` runs everything CI runs except the image build and
Trivy: Ruff, Bandit, pytest (90% coverage gate), actionlint, zizmor, shellcheck, manifest
validation, catalog check, `terraform fmt/validate/test`, environment-data tests, TFLint, and Checkov.

## Documentation

| Document | Contents |
|---|---|
| [architecture.md](docs/architecture.md) | Topology, environments, dev vs production network, module plan, workflow plan |
| [security-model.md](docs/security-model.md) | OIDC roles, guardrails, supply chain, documented exceptions |
| [threat-model.md](docs/threat-model.md) | STRIDE by trust boundary, mitigations, residual risk |
| [developer-guide.md](docs/developer-guide.md) | Manifest reference, local workflow, service contract |
| [deployment-plan.md](docs/deployment-plan.md) | AWS assessment, owner decisions, phase roadmap, commands |
| [cost-model.md](docs/cost-model.md) | Unit prices (to verify), demo/continuous estimates, budgets |
| [rollback-runbook.md](docs/rollback-runbook.md) | Circuit breaker, digest rollback, infra revert, drift, cleanup |
| [portfolio-evidence.md](docs/portfolio-evidence.md) | Timestamped test results and defects found |
| [phase-0-assessment.md](docs/phase-0-assessment.md) | Repository, reference-project and tooling assessment |
| [aws-discovery-2026-11-23.md](docs/aws-discovery-2026-11-23.md) | Live AWS account discovery (redacted) and its Phase 3 impact |
| [bootstrap-runbook.md](docs/bootstrap-runbook.md) | Step-by-step bootstrap from AWS CloudShell, verification, GitHub environments |
| [github-settings.md](docs/github-settings.md) | Branch ruleset, secret scanning, Actions defaults: apply + verify |
| [docs/adr/](docs/adr) | Architecture decision records |

## Cost

Offline development costs **$0**. A 3-hour demo is estimated at **≈ $0.17–$0.25**, and
continuous running at **≈ $38–$45/month** (mostly ALB, public IPv4 and Fargate; no NAT Gateway,
no EKS). These are **unverified list-price estimates**. Demos are torn down by approved cleanup;
budgets only notify. See [docs/cost-model.md](docs/cost-model.md).

## Safety rules this project follows

No long-lived AWS keys · no AWS role assumable from pull requests · no `terraform apply`/`destroy`
without a reviewed plan and a human approval · images deployed by digest only · security
exceptions documented with compensating controls · no claims without evidence.
