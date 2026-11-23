# Portfolio evidence

Real, timestamped results only. No metric here is estimated or invented. Where something has not
been executed, it says so. All times are UTC.

## Phase 2 — CI and security automation (2026-11-23)

### Local validation (before the first GitHub run)

| # | Check | Result | Time (UTC) |
|---|---|---|---|
| P2-1 | `make check` (now also: actionlint, zizmor, shellcheck, Checkov guard, TFLint, env data) | ✅ exit 0 | 01:43:38–01:46:02 |
| P2-2 | pytest (incl. 23 repo-hygiene tests) | ✅ 101 passed | 01:46 |
| P2-3 | Terraform tests: stack 15, ecs-service 7, env data dev/staging/prod 1 each | ✅ all passed | 01:46 |
| P2-4 | TFLint 0.66.0 + AWS ruleset 0.50.0 (both built from source here) | ✅ 0 issues (92 skeleton `unused_declarations` scoped away, SE-7) | 01:46 |
| P2-5 | actionlint 1.7.12, zizmor 1.33.1 | ✅ no findings | 01:46 |
| P2-6 | Checkov `github_actions` | ✅ 156 passed, 0 failed (after fixing a silent skip, see below) | ~01:50 |
| P2-7 | shellcheck (warning level) on `scripts/*.sh` | ✅ clean | ~01:55 |
| P2-8 | Hygiene mutation test: unpinned action + `id-token: write` in CI + `${{ github.event.pull_request.title }}` in `run:` | ✅ 3 targeted tests failed as intended; file restored | ~01:41 |
| P2-9 | Bad environment data (`log_retention_days = 365` in dev) | ✅ rejected: `Invalid value for variable` | ~01:30 |
| P2-10 | Action SHAs verified against upstream tags (`git ls-remote`, peeled for annotated tags) | ✅ 8/8 match; all are the latest releases | 01:13 |
| P2-11 | Provider lock files: 5 platforms, zips checked against HashiCorp SHA256SUMS | ✅ | ~01:35 |

### Defect found in Phase 2

| Defect | How it was found | Fix |
|---|---|---|
| Checkov's GitHub Actions scan **silently evaluated 0 checks** on `ci.yml` | Output showed results only for Terraform and Dockerfile; a JSON run reported `resource_count: 0`; bisected to `cancel-in-progress: ${{ … }}` failing Checkov's workflow schema | Literal `cancel-in-progress: true` with a per-commit group on `main`; new `make checkov-guard` (in CI) fails if Checkov evaluates zero workflow checks |

### On GitHub

Recorded from the pull request's CI runs (see the PR checks and the section below once runs complete).

## Phase 1 — offline validation (2026-11-23)

Environment: Linux build container, Python 3.13.18, Terraform 1.17.2, AWS provider 6.73.0
(checksum-verified from releases.hashicorp.com), Docker, Checkov 3.4.6, Bandit 1.9.4, Ruff 0.16.9,
Trivy (container image `aquasec/trivy:latest`). **No AWS credentials; no AWS resources created.**

| # | Check | Command | Result | Time |
|---|---|---|---|---|
| E1 | Full offline suite | `make check` | ✅ exit 0 | 01:06:56–01:07:34 |
| E2 | Unit tests + coverage gate (90%) | `pytest --cov` | ✅ 78 passed; 98.51% branch-aware coverage | 01:07 |
| E3 | Lint / format | `ruff check`, `ruff format --check` | ✅ all checks passed; 21 files formatted | 01:07 |
| E4 | Python SAST | `bandit -r apps scripts` | ✅ no findings (1 justified `nosec`, SE-3) | 01:07 |
| E5 | Manifest validation | `scripts/validate_service.py apps/*/service.yaml` | ✅ `OK apps/sample-api/service.yaml` | 01:07 |
| E6 | Catalog freshness | `scripts/generate_catalog.py --check` | ✅ up to date | 01:07 |
| E7 | Terraform fmt + validate (11 dirs) | `make tf-validate` | ✅ 11/11 valid | 01:07 |
| E8 | Terraform guardrail tests (stack) | `terraform test` | ✅ 14 passed, 0 failed (15 after ADR 0005 added the us-east-1 rejection test) | 01:07 |
| E9 | Terraform contract tests (ecs-service) | `terraform test` | ✅ 7 passed, 0 failed | 01:07 |
| E10 | Checkov IaC + Dockerfile + secrets | `make security` | ✅ Dockerfile 85/0, Terraform 1/0, secrets clean | 01:07 |
| E11 | Trivy misconfig + secret scan of repo | `trivy fs --scanners misconfig,secret` | ✅ 0 findings | ~01:00 |
| E12 | Container build | `docker build` | ✅ (sandbox variant, see note) | 00:54 / 01:01 |
| E13 | Hardened container smoke test | `--read-only --cap-drop ALL --security-opt no-new-privileges` | ✅ UID 10001; `/health` 200, `/ready` 200, `/version` 200 with build metadata; `/metrics` 404 and `/docs` 404 (disabled); `X-Request-ID` and `nosniff` headers; Docker HEALTHCHECK `healthy`; no `pip` in image | 00:54 |
| E14 | Graceful shutdown | `docker stop -t 30` | ✅ exit code 0 after 0.43 s; JSON log `"event":"shutdown"` before `Application shutdown complete` | 00:54 |
| E15 | Trivy image scan (HIGH/CRITICAL, fixable) | `trivy image` | ❌ **1 HIGH**: zlib1g CVE-2026-85091 (fixed in `1:1.3.dfsg+really1.3.1-1+deb13u1`). Python packages: 0 findings | ~00:56 |

### Scenario 3 preview: insecure changes fail validation (offline)

A hostile manifest (captured 2026-11-23 ~01:08):

```text
FAIL hostile-service.yaml
  - spec: Additional properties are not allowed ('iamPolicy', 'region' were unexpected)
```

After the structural escape was removed, the policy layer rejected the rest:

```text
FAIL hostile-service.yaml
  - metadata/owner: 'team-unknown' is not an approved team
  - metadata/name: 'admin' is reserved
  - metadata/tags/owner: tag is set by the platform and cannot be overridden
  - spec/environmentVariables/DB_PASSWORD: looks like a secret; declare it in spec.secrets
  - spec/environments/dev/desiredCount: 5 exceeds the dev limit of 2
```

Terraform equivalents (E8/E9): `0.0.0.0/0` over HTTP, `/24` over HTTP, prod without HTTPS,
wrong-account credentials, unapproved region, `:latest` image tag and non-ECR registry are all
rejected at plan time.

### Defects found during Phase 1 validation (and fixed)

| Defect | How it was found | Fix |
|---|---|---|
| Background `docker build … \| tail` reported success although the build failed | Image missing at smoke-test time | Same lesson as the previous project's `pipefail` incident: Makefile uses `bash -euo pipefail`. Phase 2 workflows will set `defaults.run.shell: bash` |
| `apt-get update` failures are warnings, so `apt-get upgrade` silently patched nothing and the build passed | Trivy found a fixable HIGH CVE in a "patched" image; the build log showed `W: Failed to fetch` | `apt-get update --error-on=any`; verified that the build now **fails** when mirrors are unreachable |
| `FROM ${PYTHON_IMAGE}` hid the digest pin from Checkov (CKV_DOCKER_7), and a build arg could swap the base image | Checkov | Digest hard-coded in both stages; Checkov 85/85 |
| Uvicorn's `color_message` field leaked ANSI escape codes into JSON logs | Container log review | Field excluded from the formatter |
| `cost-center` tag was wrongly reserved, rejecting the sample manifest | Catalog generation | Removed from `reserved_tag_keys` |

### Notes on the sandbox build (honesty about E12)

The build environment sits behind a TLS-intercepting proxy that blocks Debian package mirrors.
To run E12–E15 locally, the image was built from a **sandbox-only** base that trusts the proxy CA.
For the final rebuild (01:01) the `apt-get update/upgrade` lines were removed from a scratch copy.
The committed `apps/sample-api/Dockerfile` was not modified for this. The first GitHub Actions
build (Phase 2) is the authoritative result and must close E15.

## Phase 0 — AWS discovery

⏸️ Not executed: no valid AWS credentials (`InvalidClientTokenId`). Owner to run
`scripts/aws_discovery.sh` (read-only). See [deployment-plan.md §1](deployment-plan.md#1-phase-0--aws-environment-assessment-2026-11-23).

## Required scenarios (Phase 8 checklist)

| # | Scenario | Status |
|---|---|---|
| 1 | Developer creates a new service from a template | 📋 Phase 6 |
| 2 | PR triggers tests and security scans | 🛠️ Phase 2 (`ci.yml`); GitHub run results recorded above |
| 3 | Insecure Terraform change fails validation | ✅ offline (E8, E9); 📋 in CI on a PR |
| 4 | Container image built and scanned | ✅ locally (E12, E15, finding open); 📋 in CI |
| 5 | Approved image published to ECR | 📋 Phase 5 |
| 6 | Authorized deployment updates ECS Fargate | 📋 Phase 5 |
| 7 | Unapproved deployment is blocked | 📋 Phase 5 |
| 8 | Application passes health checks | ✅ locally (E13); 📋 behind ALB |
| 9 | Failing release is rolled back | 📋 Phase 7 |
| 10 | Configuration drift detected | 📋 Phase 7 |
| 11 | CloudWatch records deployment and application events | 📋 Phase 4/7 (JSON logging ✅ E13) |
| 12 | Cleanup removes billable workload resources | 📋 Phase 7 |
