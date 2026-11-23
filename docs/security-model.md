# Security model

Status legend: 📋 Planned · 🛠️ Implemented · ✅ Tested offline · ☁️ AWS-verified. Nothing is ☁️ yet.

## 1. Principles

1. **No long-lived AWS credentials anywhere**: GitHub OIDC with short-lived (≤ 1 h) sessions.
2. **Developers describe, the platform decides**: the manifest has no IAM, network, region or
   resource fields, so it cannot express a privilege escalation.
3. **Every AWS change passes two humans' worth of friction**: a reviewed PR, then an environment approval.
4. **Immutable artifacts**: images by digest, plans by SHA-256, base images by digest.
5. **Fail closed**: validation errors, scan findings, stale plans, wrong account or wrong region stop the pipeline.

## 2. Identity and access

### 2.1 GitHub OIDC roles 📋 (Phase 3; interface 🛠️ in `terraform/modules/iam-oidc`)

| Role | Trusted `sub` (exact `StringEquals`) | Allowed | Explicitly not allowed |
|---|---|---|---|
| `idp-<env>-github-plan` | `repo:oteyami2001/Internal-Developer-Platform-CI-CD-Automation:environment:<env>-plan` | Describe/List/Get of project services; read state + write lock file | Data reads (S3 objects outside state, Secrets values, logs content), any write |
| `idp-<env>-github-apply` | `…:environment:<env>` | Writes to project services, **conditioned on `aws:RequestedRegion`**; IAM only on `idp-<env>-*` roles **with the permissions boundary** | Creating users or access keys, removing boundaries, Organizations/account, CloudTrail tampering, editing CI roles |
| `idp-github-image-push` | `…:ref:refs/heads/main` | `ecr:GetAuthorizationToken`; push to project repositories | Delete images, change repository policy or mutability |
| `idp-<env>-github-deploy` | `…:environment:<env>-deploy` | `ecs:RegisterTaskDefinition`, `ecs:UpdateService`/`Describe*` on one cluster; `iam:PassRole` for that env's task/execution roles only | Terraform state, any other service |

All trust policies also require `aud = sts.amazonaws.com`. **No role trusts `pull_request`**
([ADR 0003](adr/0003-no-oidc-trust-for-pull-requests.md)). Subjects are shown in the short form. This
repository uses **immutable-ID subjects** (verified via the GitHub API on 2026-11-23), so the real
prefix is `repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837`.

### 2.1a Shared account ([ADR 0005](adr/0005-shared-account-with-aiops-project.md))

The account also hosts the AIOps project's retained bootstrap. The GitHub OIDC provider is shared
and only looked up. Role trust is per repository, so neither project's workflows can assume the
other's roles. The `idp` apply role will add `aws:ResourceTag/Project = idp` conditions where APIs
support them, and explicitly deny writes to `aiops-*` IAM, S3 and ECR resources. The AIOps apply
role is broader (`ecs:*`, `elasticloadbalancing:*` on `*` in us-east-2), which is exception SE-6.

### 2.2 Permissions boundary 📋
Every role created by the apply role must carry the workload boundary (an `iam:PermissionsBoundary`
condition on `CreateRole`/`Put*Policy`), as in the previous project, whose boundary design is reused
after review. The boundary denies IAM writes, Organizations/account/billing and CloudTrail changes.

### 2.3 Workload roles 📋
- **Execution role** (per service): pull from its ECR repository, write its log group, read only
  `idp/<env>/<service>/*` secrets.
- **Task role** (per service): empty by default. The sample app calls no AWS APIs.

## 3. Developer guardrails (🛠️✅ today)

Two layers, both run in `make check` and (Phase 2) in required CI checks:

| Guardrail | Where | Test |
|---|---|---|
| Unknown fields rejected everywhere (no `iamPolicy`, `region`, `securityGroupIngress`, `privileged`, arbitrary `resources`) | `service.schema.json` `additionalProperties: false` | `test_schema_rejects` |
| Name, owner, port ≥ 1024, Fargate CPU/memory combos, health-check path, rolling only | Schema | `test_schema_rejects` |
| Approved teams, reserved names, platform-owned tags cannot be overridden | Policy | `test_policy_rejects` |
| Secret-looking plain env vars rejected (`*PASSWORD*`, `*TOKEN*`, `AKIA…`, private keys, `ghp_…`) | Policy | `test_policy_rejects` |
| Secrets referenced only by short name, mapped to `idp/<env>/<service>/<name>` | Validator `render()`; Terraform `secret_arns` validation | `test_render_…`, `foreign_secret_namespace_is_rejected` |
| Per-environment limits (dev ≤ 2 tasks and ≤ 0.5 vCPU; prod ≥ 2 tasks, circuit breaker on, min healthy 100%) | Policy | `test_policy_rejects` |
| Duplicate YAML keys rejected (a reviewer sees one value, a parser applies another) | `_UniqueKeyLoader` | `test_duplicate_yaml_keys_are_rejected` |
| YAML cannot instantiate Python objects | `SafeLoader` subclass | `test_yaml_tags_cannot_execute_code` |
| Service name unique, matches its directory | Validator | `test_name_must_match_directory`, `test_duplicate_service_names_across_manifests` |

Guardrail files (`platform/schemas/`, `platform/policy/`) are owned by the platform team via
`CODEOWNERS`. Code-owner review cannot be required while there is a single maintainer (SE-5); the
`main` ruleset still forces every change through a PR with a green `ci-ok`.

## 4. Infrastructure guardrails (🛠️✅ today, offline `terraform test`)

- Wrong-account credentials fail the plan (provider `allowed_account_ids` **and** a caller-identity postcondition).
- Region restricted to an approved list; provider region must match.
- Plain HTTP ingress must be `/32`; `0.0.0.0/0` is accepted only with an ACM certificate (HTTPS).
- prod requires HTTPS; non-prod log retention ≤ 30 days; budget 1–200 USD.
- ECS images must be `<account>.dkr.ecr.<region>.amazonaws.com/…@sha256:<digest>`. Tags such as `:latest` and non-ECR registries are rejected.
- Hard-coded, non-configurable task settings (Phase 4): `readonlyRootFilesystem`, non-root user, no privileged mode.

## 5. Supply chain

| Control | Status |
|---|---|
| Base image pinned by digest, not a build argument | 🛠️✅ (Checkov 85/85 Dockerfile checks pass) |
| Multi-stage build, pip/setuptools removed from runtime image | 🛠️✅ (verified `no-pip` in container) |
| Non-root UID 10001, read-only root FS, all capabilities dropped | 🛠️✅ (local container smoke test) |
| `apt-get update --error-on=any`: unreachable mirrors fail the build | 🛠️✅ (found in Phase 1: without it the build silently skipped OS patches) |
| Trivy image gate (HIGH/CRITICAL with fixes) | ✅ `ci.yml` `container` job passes on GitHub runners (run 45097129693). The sandbox-only zlib1g finding (SE-4) is closed |
| Trivy filesystem scan (dependencies, misconfig, secrets) | 🛠️ `ci.yml` `trivy-fs` · ✅ locally 0 findings |
| Exact dependency pins; Dependabot for pip, Docker digests, Actions SHAs and Terraform providers (with release cooldowns) | 🛠️ `.github/dependabot.yml` |
| GitHub Actions pinned to full commit SHAs (verified against upstream tags); `permissions: {}` + per-job grants; no `pull_request_target`; no `${{ }}` in `run:` | 🛠️✅ `test_repo_hygiene.py` (mutation-tested: an unpinned action, `id-token: write` in CI, and an expression injection each fail) |
| Workflow linters: actionlint, zizmor (Actions security), Checkov `github_actions` + a guard that fails if Checkov evaluated zero checks | 🛠️✅ |
| Terraform provider lock files for 5 platforms, CI `init -lockfile=readonly` | 🛠️✅ |
| SBOM (Syft/Trivy CycloneDX) attached to each image build | 📋 Phase 5 |
| ECR tag immutability + scan on push | 📋 Phase 3 |

## 6. Secrets

- No secrets exist in the MVP. When needed: AWS Secrets Manager, injected through the ECS `secrets`
  field (resolved at task start by the execution role). Values never enter Terraform variables or state.
- The Terraform plan artifact is still treated as sensitive: short retention, never printed in full.
- Secret scanning: Trivy + Checkov secrets ✅ clean locally and in CI; GitHub secret scanning + push
  protection (free for public repositories): owner enables, `scripts/verify_github_settings.sh`
  verifies ([github-settings.md](github-settings.md)).

## 7. Audit and evidence

- CloudTrail (account trail: existence to be confirmed by discovery) records every role session.
  The OIDC `sub` appears in the `AssumeRoleWithWebIdentity` event.
- GitHub records environment approvals (who, when) and deployment history.
- `docs/portfolio-evidence.md` records timestamped, real results only.

## 8. Documented security exceptions

| ID | Exception | Justification | Compensating control | Review |
|---|---|---|---|---|
| SE-1 | Dev Fargate task in a public subnet with a public IP | Avoids NAT Gateway cost (~$33+/month) for a demo | Task SG allows only the ALB SG; demo-only lifetime; prod reference uses private subnets | Phase 4 |
| SE-2 | Dev ALB over HTTP | No domain or certificate for the demo | Terraform rejects anything but `/32` ingress without HTTPS (✅ tested); no credentials over the endpoint | Phase 4 |
| SE-3 | `# nosec B506` on `yaml.load` in `scripts/validate_service.py` | Loader is a `yaml.SafeLoader` subclass (adds a duplicate-key check). Bandit cannot see the subclass | `test_yaml_tags_cannot_execute_code` proves `!!python` tags are rejected | Permanent |
| ~~SE-4~~ **Closed 2026-11-23** | Local image had 1 HIGH OS CVE (zlib1g CVE-2026-85091, fix available) | This sandbox's network policy blocks Debian mirrors, so `apt-get upgrade` cannot run here. The Dockerfile now **fails** rather than skipping the upgrade | Image never published. **Closed:** the GitHub-runner build passed the Trivy HIGH/CRITICAL gate in runs 45096890726 and 45097129693 | Closed |
| SE-6 | Shared account with the AIOps project, whose apply role can write ECS/ELB/VPC resources account-wide in us-east-2 | Owner decision to reuse the account (ADR 0005) | AIOps pipeline is manual and approval-gated, and its environment is destroyed. `idp` resources are tagged and monitored for drift; recommend tag conditions in the AIOps repo | Phase 3 |
| SE-5 | Single maintainer: environment approvals cannot be two-person, and the `main` ruleset requires 0 approvals and no code-owner review (an author cannot approve their own PR) | Solo portfolio project | PR + `ci-ok` required, no force push or deletion, no bypass actors; approval gates still force a deliberate, logged human step; raise to 1 approval + code-owner review when a second maintainer joins | Ongoing |
| SE-7 | TFLint `terraform_unused_declarations` ignored file-by-file in skeleton `variables.tf` | Interface-only skeletons declare inputs that nothing uses yet | Other rules still apply (verified); `test_unused_declaration_ignore_only_while_skeleton` fails as soon as a configuration gains resources | Phase 3/4 (auto-enforced) |
