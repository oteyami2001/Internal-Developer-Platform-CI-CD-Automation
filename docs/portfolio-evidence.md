# Portfolio evidence

Real, timestamped results only. No metric here is estimated or invented. Where something has not
been executed, it says so. All times are UTC.

## Python version standard (2026-11-23, ADR 0006)

Owner decision: stay on Python 3.13; Dependabot PR #2 (base image 3.13 → 3.15) is reverted.

| # | Check | Result |
|---|---|---|
| PY-1 | All runtime + dev dependencies (36 distributions) resolve as CPython 3.13 wheels only, linux/x86_64 and linux/arm64 | ✅ |
| PY-2 | Direct pins declare 3.13 support (`requires_python`); compiled deps ship `cp313` wheels (pydantic-core, PyYAML, rpds-py, coverage) | ✅ (`httpx` 0.28.1 has no 3.13 classifier; pure Python, tested on 3.13 in CI) |
| PY-3 | Latest `python:3.13-slim` = Python 3.13.18, multi-arch digest `e48f59cd…` (same image CI scanned in Phase 2) | ✅ |
| PY-4 | Consistency tests: replaying PR #2, allowing Dependabot minor jumps, and moving CI to 3.15 each fail `test_repo_hygiene.py` | ✅ 3/3 caught |

## Phase 3 — Terraform bootstrap (2026-11-23)

Approved by the owner on 2026-11-23 with a $25 project budget and the CloudTrail trail. Code and
offline tests are done; **the AWS apply is performed by the owner** from CloudShell
([bootstrap-runbook.md](bootstrap-runbook.md)). Nothing below is AWS-verified yet.

### Offline validation

| # | Check | Result | Time (UTC) |
|---|---|---|---|
| P3-1 | `make check` (whole repository) | ✅ exit 0 | 03:13:37–03:14:32 |
| P3-2 | New `terraform test` suites: iam-oidc 8, bootstrap 7, ecr 5, budgets 2, security 1 | ✅ 23/23 passed | 03:14 |
| P3-3 | Mutation testing of the Terraform assertions (10 deliberate weakenings, e.g. `StringLike` trust, plan role gains `s3:PutObject`, apply role trusts `pull_request`, aiops deny weakened, boundary condition removed, mutable ECR tags, trail validation off, public state bucket, OIDC provider no longer looked up) | ✅ **10/10 caught**, files restored | ~03:02 |
| P3-4 | Checkov (Terraform) | ✅ 49 passed, 0 failed, 21 skipped (each with inline justification) | 03:14 |
| P3-5 | TFLint + AWS ruleset | ✅ 0 issues, after fixing 2 findings: unused guard data sources (now outputs) and a null template in standalone module evaluation | ~03:05 |
| P3-6 | Trivy fs (misconfig, secrets, vulnerabilities; all severities) | ✅ 0 findings (3 LOW and the HIGH SSE/CloudTrail items carry justified inline ignores) | ~03:08 |
| P3-7 | `scripts/verify_bootstrap.sh` against stubbed AWS responses | ✅ a correct bootstrap passes 20/20; a broken one fails exactly the 4 broken controls (versioning suspended, wildcard trust, missing role ×2) | 03:11 |
| P3-8 | shellcheck (new scripts) | ✅ clean | ~03:10 |

### AWS apply

**Runbook steps 1–2 done** (owner, CloudShell, 2026-11-23): Terraform 1.17.2 installed,
`aws sts get-caller-identity` returned the expected account, Region us-east-2, role
`AccountFullAccessRole`.

⏳ Pending: owner runs [bootstrap-runbook.md](bootstrap-runbook.md) after this PR merges. Record
here: the plan line (expected `28 to add, 0 to change, 0 to destroy`), the apply summary, the
`verify_bootstrap.sh` output, and the `verify_github_settings.sh` output with environments.

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

### On GitHub: [PR #1](https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/pull/1)

| Run | Head | Result | Notes |
|---|---|---|---|
| [45096890726](https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/actions/runs/45096890726) | `e255350` | ❌ `ci-ok` failed (5/6 jobs green) | Workflows job could not install `actionlint-py==1.7.12`: the package uses 4-part versions. **Container job green: Trivy image gate passed on the runner**, so the zlib1g CVE seen only in the sandbox build is fixed (SE-4 closed). Terraform job 2 min 1 s. |
| [45097129693](https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/actions/runs/45097129693) | `b586952` | ✅ all 8 checks green, `ci-ok` success 01:55:28 | Pin fixed (`1.7.12.25`). Terraform job down to 1 min 20 s with the in-run provider cache. Checkov SARIF uploaded, so GitHub code scanning is active |

PR #1 was merged by the owner at 2026-11-23 01:56:42 UTC (merge commit `a4a9438`).

### GitHub settings, baseline (owner ran `scripts/verify_github_settings.sh` at 2026-11-23T02:06:44Z)

Run in a Codespace, so `gh` used the Codespace `GITHUB_TOKEN`:

| Control | Result | Meaning |
|---|---|---|
| Default branch | ❌ `claude/stoic-volta-i07auh` | Real: still to switch to `main` |
| `main` ruleset | ❌ no active rules | Real: not yet applied |
| Secret scanning, push protection, Dependabot, Actions token defaults | reported `unknown`/`null` | **Not readable with the Codespace token**. The script (v1) wrongly printed some of these as FAIL; fixed to report `UNKNOWN` |
| OIDC subject | `use_immutable_subject: true`, prefix `repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837` | Real: used for Phase 3 trust policies |
| Repository ID | `1465573837` | Real: recorded as the bootstrap default |

### GitHub settings, applied and verified (owner, 2026-11-23)

The owner signed in to `gh` as the repository owner (`unset GITHUB_TOKEN && gh auth login`) and
applied the `docs/github-settings.md` commands:
- `default_branch=main`;
- secret scanning, push protection and Dependabot security updates enabled (the API response confirmed `"status": "enabled"`);
- Dependabot alerts enabled;
- workflow token `read` with `can_approve_pull_request_reviews=false`;
- ruleset `main-protection` created at 02:26:57Z (id 27869781, enforcement `active`, no bypass actors, `current_user_can_bypass: never`).

`scripts/verify_github_settings.sh` at **2026-11-23T02:27:41Z**:

```text
PASS     default branch
PASS     secret scanning
PASS     secret scanning push protection
PASS     Dependabot alerts
PASS     Dependabot security updates
PASS     default GITHUB_TOKEN permissions
PASS     Actions cannot approve pull requests (can_approve_pull_request_reviews)
INFO     fork PR workflow approval policy: first_time_contributors
PASS     main requires a pull request
PASS     force pushes to main blocked
PASS     deletion of main blocked
PASS     status check ci-ok required on main
INFO     code-owner review NOT required (expected while the project has a single maintainer - SE-5)
INFO     OIDC subject customization: use_immutable_subject=true, prefix repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837
INFO     environments: <none>
RESULT: all checks passed
```

GitHub added two ruleset defaults that were not in `main.json`: `require_extra_approval_for_unattributed_changes: true`
and `allowed_merge_methods: [merge, squash, rebase]`.

Dependabot opened its first PR (#3, Python dev dependencies) at 01:52Z, before the ruleset existed.
Like every PR, it must now pass `ci-ok` on an up-to-date branch before it can merge.

Not yet demonstrated on GitHub: a deliberately insecure Terraform change failing CI (scenario 3).
It needs its own PR, because PR #1 merged before the demo commit was pushed.

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

✅ Run by the owner in AWS CloudShell (us-east-2) at **2026-11-23T02:45:24Z** (from this build
environment it was blocked: `InvalidClientTokenId`). Redacted results:
[aws-discovery-2026-11-23.md](aws-discovery-2026-11-23.md). us-east-1: every regional read was an
explicit SCP deny. us-east-2: no ECS, ALB, NAT, EIP or secrets left; month-to-date cost under $0.01 per service.

## Required scenarios (Phase 8 checklist)

| # | Scenario | Status |
|---|---|---|
| 1 | Developer creates a new service from a template | 📋 Phase 6 |
| 2 | PR triggers tests and security scans | ✅ PR #1, runs 45096890726 (caught a real failure) and 45097129693 (green) |
| 3 | Insecure Terraform change fails validation | ✅ offline (E8, E9, P2-9); 📋 on a GitHub PR |
| 4 | Container image built and scanned | ✅ in CI on GitHub (run 45097129693, Trivy gate passed) |
| 5 | Approved image published to ECR | 📋 Phase 5 |
| 6 | Authorized deployment updates ECS Fargate | 📋 Phase 5 |
| 7 | Unapproved deployment is blocked | 📋 Phase 5 |
| 8 | Application passes health checks | ✅ locally (E13); 📋 behind ALB |
| 9 | Failing release is rolled back | 📋 Phase 7 |
| 10 | Configuration drift detected | 📋 Phase 7 |
| 11 | CloudWatch records deployment and application events | 📋 Phase 4/7 (JSON logging ✅ E13) |
| 12 | Cleanup removes billable workload resources | 📋 Phase 7 |
