# Threat model

Method: STRIDE per trust boundary, scored Likelihood × Impact (1–3 each). Status legend:
📋 Planned · 🛠️ Implemented · ✅ Tested offline · ☁️ AWS-verified.

## 1. Assets

| Asset | Why it matters |
|---|---|
| AWS account (IAM, billing) | Full compromise = data loss, crypto-mining bills, pivot to the organization |
| Terraform state | Resource inventory; can contain sensitive attributes |
| CI role credentials (OIDC sessions) | Direct AWS access |
| Container images in ECR | Code that runs in AWS |
| Platform guardrails (schema, policy, workflows, CODEOWNERS) | If editable by anyone, every other control can be removed |
| Budget / cost | A portfolio account has a small budget; runaway resources are a real harm |

## 2. Trust boundaries

```mermaid
flowchart LR
  A[Contributor / fork] -->|TB1: pull request| B[GitHub repo + Actions]
  B -->|TB2: environment approval| C[Privileged workflow jobs]
  C -->|TB3: OIDC AssumeRoleWithWebIdentity| D[AWS IAM roles]
  D -->|TB4: API calls| E[AWS resources]
  F[Internet client] -->|TB5: ALB listener| G[Fargate task]
  G -->|TB6: egress| H[Internet / AWS APIs]
```

## 3. Threats and mitigations

| # | Boundary | STRIDE | Threat | L×I | Mitigation | Status |
|---|---|---|---|---|---|---|
| T1 | TB1 | E | PR modifies a workflow to assume an AWS role and read state or exfiltrate | 3×3 | No role trusts `pull_request`; PR CI has no credentials; roles trust environment subjects limited to `main` (ADR 0003) | 🛠️ design · 📋 Phase 3 trust policies |
| T2 | TB1 | T | Manifest requests IAM, public SGs, other regions or arbitrary resources | 3×3 | Schema has no such fields; `additionalProperties: false` | ✅ |
| T3 | TB1 | T | Manifest smuggles a value via duplicate YAML keys or YAML object tags | 2×3 | Duplicate-key loader; SafeLoader | ✅ |
| T4 | TB1 | I | Secret committed in a manifest env var | 2×3 | Name + value heuristics in policy; Trivy/Checkov secret scan; GitHub push protection | ✅ heuristics + scans · 📋 push protection |
| T5 | TB1 | T | Developer weakens guardrails by editing schema/policy in their PR | 2×3 | CODEOWNERS on `platform/`, `terraform/`, `.github/`; `main` ruleset (PR + `ci-ok`); code-owner review once there is a second maintainer (SE-5) | 🛠️ CODEOWNERS + ruleset file · 📋 owner applies, script verifies |
| T6 | TB2 | E | Approval bypass: a branch rule or environment exists but is not actually enforced | 2×3 | `scripts/verify_github_settings.sh` reads the live rules from the API (unreadable = UNKNOWN, never PASS); `main` ruleset verified 2026-11-23; environments verified the same way in Phase 3 | ✅ `main` · 📋 environments |
| T7 | TB2 | T | Reviewer approves plan A, apply runs plan B (or a re-plan with different changes) | 2×3 | Apply re-plans and compares a SHA-256 digest over every planned change with the reviewed digest; refuses on mismatch; fails closed on a non-plan document | ✅ `test_tf_ci.py` (11 tests, mutation-tested; found and fixed a fail-open bug during Phase 4) |
| T8 | TB2 | T | Stale approval: an old queued apply runs after newer changes | 2×2 | The digest check rejects it (the plan of the current `main` + current infrastructure differs); concurrency group shared by plan and apply; job timeouts | ✅ |
| T9 | TB3 | S | Another repo/fork/branch obtains a token accepted by our roles | 2×3 | Exact `StringEquals` on `sub` and `aud` with immutable owner/repo IDs (a recreated repo with the same name is rejected); no wildcards | ✅ `iam_oidc.tftest.hcl` + mutation-tested · ☁️ after apply |
| T10 | TB4 | E | Apply role creates an admin role and escalates | 2×3 | Boundary required on every created role; deny on removing boundaries and on CI-role edits; boundary itself denies `iam:*` | ✅ module tests + mutation-tested · ☁️ after apply |
| T11 | TB4 | T | Pipeline targets the wrong account or region | 2×3 | `allowed_account_ids` + caller-identity postcondition; region allowlist + region postcondition; region-conditioned writes | ✅ (offline) |
| T12 | TB4 | D/$ | Runaway cost (forgotten resources, oversized tasks, NAT) | 3×2 | Policy size/count caps; no NAT; budget alerts; `cleanup.yml`; demo-only deploys | ✅ caps · 📋 budget/cleanup |
| T13 | TB4 | T | Mutable tag swapped to a malicious image after review | 2×3 | ECR `IMMUTABLE`; Terraform rejects non-digest images; deploy uses the digest recorded by the build | ✅ digest validation · 📋 ECR |
| T14 | TB4 | I | State/plan leakage | 2×2 | SSE-KMS, versioned, private, TLS-only state bucket with `prevent_destroy`; plan role reads only its environment prefix; **no plan artifact is ever uploaded**; IP and e-mail are sensitive variables (redacted); account ID masked in logs | ✅ bootstrap tests + workflow hygiene tests · ☁️ after apply |
| T15 | TB5 | I | Plain-HTTP demo endpoint sniffed or abused | 2×1 | `/32` ingress without TLS (validation); no sensitive data; HTTPS for prod | ✅ |
| T16 | TB5 | I | Info disclosure via `/docs`, `/openapi.json`, `/metrics`, stack traces, `Server` header | 2×1 | Docs off outside `local`; metrics off by default; generic 500 body; `--no-server-header`; security headers | ✅ |
| T17 | TB5 | T | Header injection via `X-Request-ID` into logs | 2×1 | Strict pattern, otherwise replaced with a UUID; JSON-encoded logs | ✅ |
| T18 | TB5 | D | Metric-cardinality DoS by scanning random paths | 2×1 | Unmatched routes collapse into one `unmatched` series | ✅ |
| T19 | TB6 | I | Compromised task exfiltrates via unrestricted egress (public subnet) | 1×2 | Empty task role (nothing to steal from AWS); prod uses private subnets + endpoints | 🛠️ app needs no AWS · 📋 prod reference |
| T20 | Supply chain | T | Compromised base image, dependency or GitHub Action | 2×3 | Digest-pinned base, exact pins, Trivy gates, SHA-pinned actions verified against upstream tags, Dependabot with cooldowns, scanned before merge, read-only provider lock files | 🛠️✅ |
| T21 | Supply chain | T | Build or scan "succeeds" while a security step silently did nothing | 2×2 | `pipefail` everywhere; `apt-get update --error-on=any`; `checkov-guard` fails if Checkov evaluated zero workflow checks (real defects found in Phases 1 and 2) | ✅ |
| T24 | TB1 | E | A PR edits `ci.yml` to grant itself credentials, unpin an action or inject `${{ github.event.* }}` into a shell | 2×3 | `test_repo_hygiene.py` + zizmor + actionlint fail the PR; CI holds no secrets or OIDC anyway | ✅ |
| T23 | TB4 | T | Shared account: the AIOps apply role (or a compromised AIOps pipeline) modifies `idp` ECS/ELB/VPC resources; or `idp` cleanup deletes shared resources | 1×2 | `idp` never manages `aiops-*` or the OIDC provider (data lookup); `idp` apply role tag-conditioned + explicit deny on `aiops-*`; AIOps workflows are manual + approval-gated; drift detection reports unexpected changes (ADR 0005, SE-6) | 🛠️ design · 📋 Phase 3/7 |
| T22 | Repudiation | R | Cannot prove who approved or deployed what | 2×2 | GitHub environment approval logs, CloudTrail role sessions with OIDC subject (Event history only today: **no trail exists**, 90-day retention), deployment report artifacts | ✅ trail implemented (log file validation, deletion denied) · ☁️ after apply · 📋 Phase 5 reports |
| T25 | TB4 | D | An unknown organization SCP (one denies `iam:ListAccountAliases`) blocks part of the bootstrap mid-apply | 2×1 | IAM resources planned and applied first in a small reviewed plan; Terraform keeps partial state (as in the AIOps apply #9), and nothing billable exists yet | 📋 Phase 3 |

## 4. Residual risks accepted for the MVP

- SE-1/SE-2 in [security-model.md](security-model.md#8-documented-security-exceptions) (public subnet, HTTP demo).
- Single maintainer: approvals are deliberate but not two-person (SE-5).
- Shared account with the AIOps project (T23, SE-6).
- Same-account environments: a bug in the apply role's scoping could affect another environment's
  resources. Name-prefix scoping and per-environment roles reduce the risk; separate accounts remove it (production reference).
