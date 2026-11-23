# Portfolio evidence

Real, timestamped results only. No metric here is estimated or invented. Where something has not
been executed, it says so. All times are UTC.

## Phase 8 — Validation and portfolio (2026-11-23)

| # | Check | Evidence | Result |
|---|---|---|---|
| P8-1 | Scenario 3 on a real PR: demo PR #17 set the ECR repository's tags to `MUTABLE` | Run 45278084468: Terraform test `tags must be immutable` (expected `IMMUTABLE`, actual `MUTABLE`), Checkov `CKV_AWS_51` FAILED, Trivy misconfiguration FAILED, `ci-ok` red → merge blocked. Honest note: the first run (45277567552) failed the Terraform job at `terraform fmt` (the demo comment broke alignment); the formatting-only fix let the security test run. Closed unmerged; both commits reverted | ✅ |
| P8-2 | Recruiter overview with measured numbers only ([portfolio-overview.md](portfolio-overview.md)), delivery-flow diagram ([diagrams/delivery-flow.mmd](../diagrams/delivery-flow.mmd)), refreshed architecture diagram | Counted at commit time: 241 platform tests, 27 service tests, 65 Terraform test runs, 8 workflows, 6 ADRs | ✅ |
| P8-3 | Scenario 11: CloudWatch records deployment events (owner screenshots of the `idp-dev` dashboard and the alarm list, ~22:25) | The dashboard's "ECS deployment events" widget (EventBridge → `/aws/events/idp-dev/ecs-deployments`) shows the drill timeline: 21:43:09 `SERVICE_DEPLOYMENT_IN_PROGRESS` (drill) → 21:47:53 `SERVICE_DEPLOYMENT_FAILED` → 21:47:53 `IN_PROGRESS` (automatic rollback) → **21:49:08 `SERVICE_DEPLOYMENT_COMPLETED` + `SERVICE_STEADY_STATE`**. So the bad release healed in ~6 minutes, with the dip visible on the CPU/memory widget. All 7 alarms `OK` · Application log group `/idp/dev/sample-api` (owner screenshots, ~22:30): retention 1 week (as coded), **8 log streams, one per task**, last events 08:38–09:05 (Phase 5 releases) and 21:43–21:47 (the drill's crashing tasks and the rollback). Stream contents were not opened in the screenshots | ☁️ |
| P8-4 | **Scenario 12: cleanup**. Destroy plan: terraform-plan run 45282787268 (`mode = destroy`, 22:46): `Plan: 0 to add, 0 to change, 47 to destroy.` = network 18, observability 16, service 7, load balancer 4, cluster 2. Nothing from the bootstrap, ECR, state, CloudTrail or other projects. No account ID, IP or e-mail in the log | `cleanup` run 45283263149, owner approved `dev`, 22:53:46–22:56:59: digest matched; `Apply complete! Resources: 0 added, 0 changed, 47 destroyed.`; **`Cleanup of dev verified.`** (empty state, no `idp-dev` load balancer) | ☁️ |
| P8-5 | Defect found after cleanup: the weekly drift detection would have reported the whole removed environment as drift (a false issue every Monday) | `tf_ci.sh drift` now reports "not deployed (empty state)" and exits 0; test + mutation check | ✅ fixed |

## Phase 7 — Operations and recovery (code, 2026-11-23)

Approved by the owner 2026-11-23. Code and offline tests. The AWS drills (circuit-breaker
rollback, manual drift, cleanup) follow, each recorded below when run.

| # | Check | Result |
|---|---|---|
| P7-1 | `tf_ci.sh drift`: no drift → exit 0; drift → exit 3 + report with resource addresses and actions only (a planned value is verified absent); never applies; refused in destroy mode | ✅ 3 tests |
| P7-2 | `TF_MODE=destroy`: `plan -destroy` is passed; the "never delete the service" guard applies to normal plans only; destroy needs `CONFIRM_DESTROY=destroy-dev`; after destroying, the state must be empty and the `idp-dev` load balancer gone, or the job fails | ✅ 5 tests |
| P7-3 | Digest bound to the mode: the same plan document gives different digests for apply and destroy, so a reviewed apply never authorises a destroy and vice versa | ✅ |
| P7-4 | `report_drift.sh`: one open `drift` issue per environment, later runs comment on it; unknown environment or missing report refused | ✅ 3 tests (gh stubbed) |
| P7-5 | Workflow rules: drift detection is read-only (`dev-plan`, `tf_ci.sh drift`, never apply/TF_MODE); only cleanup and terraform-plan may set `TF_MODE`; cleanup requires digest + typed confirmation + `dev` approval; the drill image is proven to crash and scanned before any credentials, and contains no application code | ✅ 4 rules |
| P7-6 | Mutation testing: drift falls through, mode not in digest, confirmation not checked, leftover state not verified, leftover load balancer not verified, service guard disabled, duplicate drift issues | ✅ 7/7 caught |
| P7-7 | Lint and scans: Ruff, Bandit, actionlint, zizmor, shellcheck, Checkov (dockerfile 175 passed, github_actions 408 passed, 0 failed) | ✅ |
| P7-A0 | First `drill-image` run 45271338917 (21:36) | **Blocked by the Trivy gate, as designed:** the drill Dockerfile used the unpatched base image (zlib1g HIGH; pip-vendored msgpack/urllib3 and setuptools HIGH, all with fixes). Nothing was pushed. Fix: the same OS patching and pip removal as the service image, plus a hygiene test that every Dockerfile has both | ❌ → fixed |
| P7-A0b | `drill-image` run 45272042704 (21:40, after the fix) | Built; **proven to exit with an error**; Trivy 0 vulnerabilities; pushed `drill-crash-2139f6b…` = `sha256:24790e7d…568b224` (single manifest) | ✅ |
| P7-A1 | **Circuit-breaker drill** (scenario 9): `app-deploy` run 45272318380 with the drill digest, owner approved `dev-deploy` | `Registered idp-dev-sample-api:5`; rollout `IN_PROGRESS` 21:43 → **`FAILED` 21:48:07**: "ECS deployment circuit breaker: tasks failed to start." The job **failed as designed**, and the service stayed on / returned to revision 4 (minimum healthy 100%: the old task kept serving). ECS events (P8-3): rollback deployment `COMPLETED` at 21:49:08 | ✅ |
| P7-A2 | **Drift drill** (scenario 10): owner edited the `idp-dev-latency-p95` description in the console (~21:55) | `drift-detection` run 45274612556: `Plan: 0 to add, 1 to change, 0 to destroy`, issue **#15 "Drift detected: dev"** opened with the address only, run failed, **nothing changed**. Restored through the reviewed flow: plan run 45274873631 (it also revealed that the console silently set `datapoints_to_alarm = 2`), apply run 45275325130 with the reviewed digest + `dev` approval (22:00–22:01). Drift run 45276242898: **no drift**; issue #15 closed | ✅ |
| P7-A3 | Cleanup verified | ⏳ (on request: it removes the running environment) |

## Phase 6 — Self-service (code, 2026-11-23)

Approved by the owner 2026-11-23. Offline only: Phase 6 creates no AWS resources.
Exit criterion: *a new service created from the template passes CI unchanged.*

| # | Check | Result |
|---|---|---|
| P6-1 | `scripts/new_service.py orders-api --owner team-payments …` into a temporary `apps/`: the generated manifest passes schema + policy, **its own test suite passes with the 90% coverage gate**, Ruff `check` + `format --check` pass, and it appears in the catalog and catalog page | ✅ `test_new_service.py` |
| P6-2 | Template ≡ reference service: rendering the template with `sample-api`'s values reproduces `apps/sample-api` byte for byte (11 files) | ✅ |
| P6-3 | Invalid requests are refused before anything is written: bad names (3 cases), unapproved team, reserved name, short description, quotes; an existing service is never overwritten | ✅ 9 cases |
| P6-4 | Every service is tested on its own (`make test-apps`, `scripts/test_services.py`), so a new service is picked up by CI with no workflow change; CI summary lists each suite | ✅ sample-api 27 tests, 100% coverage |
| P6-5 | Catalog page `docs/service-catalog.md` generated and staleness-checked with the YAML catalog | ✅ |
| P6-6 | Deploy-request issue form: digest, environment, rollback digest required; **no workflow may run on issue events** (public issue text is untrusted) | ✅ hygiene test |
| P6-7 | Dependabot covers `/apps/*` and `/platform/templates/*` (pip + docker) in one grouped PR; every Dockerfile (services + template) digest-pinned to Python 3.13 | ✅ hygiene tests |
| P6-8 | Mutation testing: reference/template drift, skipped policy check, module name not rendered, catalog page staleness not checked, template dropped from Dependabot | ✅ 5/5 caught |

**Honest scope:** a second service passes CI and joins the catalog. Running it in AWS still needs a
platform change: its own ECR repository (bootstrap), a multi-service environment stack, and
`image-build`/`app-deploy` parameterised by service. It is requested with a Deploy request issue and
listed as future work.

## Phase 5 — Delivery pipeline (2026-11-23)

Approved by the owner 2026-11-23 ([release-runbook.md](release-runbook.md)).

### AWS (☁️ AWS-verified)

| # | Step | Evidence | Result |
|---|---|---|---|
| P5-A1 | `image-build` run 45126795712, 06:50 (started automatically by the merge of PR #7) | Build, hardened smoke test, Trivy gate, SBOM artifact, then push with the image-push role. `idp/sample-api:git-20df65c…` = `sha256:09dbd1aa…59ec06`, 37 s | ✅ |
| P5-A2 | First release plan (run 45134130274, 07:51, after the log fix) | `Plan: 10 to add, 1 to change, 0 to destroy.`: 7 service resources, 3 service alarms, dashboard widget. The log shows the IP, account ID and e-mail only as `***` (checked by search) | ✅ |
| P5-A3 | `terraform-apply` run 45134553241, 07:55–07:57, owner approved `dev` | Reviewed digest `d212d307…99493831` matched; `Apply complete! Resources: 10 added, 1 changed, 0 destroyed.`; ECS service steady after 1 min 27 s | ✅ |
| P5-A4 | `/health` from the operator's browser | `{"status":"ok"}` (was `503` before the release) | ✅ |
| P5-A5 | CloudWatch (owner screenshot, ~08:01) | 7 alarms, all `OK`; `HealthyHostCount` = 1. `no-healthy-targets` was briefly in ALARM because it was created seconds before the first task started | ✅ |
| P5-A6 | Drift check, run 45135379914, 08:02 | **Drift found:** `1 to add, 1 to destroy`. The task definition would be replaced because of the defaults ECS stores (defect below) | ❌ → fixed (PR #9) |
| P5-A6b | Drift check after the fix, run 45139612183, 08:34 | `No changes. Your infrastructure matches the configuration.` | ✅ |
| P5-A7 | `app-deploy` run 45139839358 (scenario 6), owner approved `dev-deploy` | `Registered idp-dev-sample-api:2`, rollout `IN_PROGRESS` → `COMPLETED` 08:36:44–08:39:07, `Deployed idp-dev-sample-api:2: 1 healthy target(s), 150s.` Role ARN masked | ✅ |
| P5-A7b | `image-build` run 45141823483 (merge of PR #10, 08:50) | Single image manifest accepted by the new push check: `git-829fbb3…` = `sha256:5e3b3b4b…609413d` | ✅ |
| P5-A7c | `app-deploy` run 45142009342 (real release of the new image), owner approved | `idp-dev-sample-api:3`, rollout `COMPLETED` 08:52:53–08:55:14, `1 healthy target(s), 146s` | ✅ |
| P5-A7d | `app-deploy` run 45143557865, approved by mistake instead of rejected | Re-deployed the same digest as revision 4 (09:03–09:06); no functional change, no downtime. Recorded for honesty | ✅ (unintended) |
| P5-A8 | Rejected deploy, run 45145248304 (scenario 7), owner clicked **Reject** on `dev-deploy` at ~09:15 | Run conclusion `failure`; the job has **no runner and no steps**, so it never requested OIDC credentials and AWS was not touched | ✅ |

**Defect found in AWS: the image is an index with untagged children.** The owner's ECR screenshot
showed 3 entries for one push: the tagged `Image Index` (`sha256:09dbd1aa…`, the digest we deploy)
plus two **untagged** manifests: the amd64 image and a 0-byte BuildKit provenance attestation. Our
lifecycle rule expires untagged images after 1 day, and the "keep newest N" rule counts every
manifest. Whether ECR's lifecycle spares the children of a tagged index was not verified. If it
does not, the running service could fail to pull its own image on the next task restart. Fix:
`make image` builds with `--provenance=false --sbom=false` (one plain manifest; the SBOM still
comes from Trivy). `push_image.sh` refuses to publish a digest unless the tag points at a single
image manifest (tests, mutation-checked). The next build therefore publishes a single manifest,
and releasing it replaces the index-based image in the service.

**Defect found in AWS: perpetual task-definition replacement.** ECS returns the container
definition in a normalised form. It adds `hostPort` (= `containerPort` in awsvpc mode) and empty
`mountPoints`, `volumesFrom`, `systemControls` and `capabilities.add`. Terraform saw each of
these as a change that forces replacement, so every plan would register a new revision and
deregister the old one. The mocked-provider tests could not see this: only a real ECS round trip
shows it. Fix: the module writes those defaults out. A contract test pins them (and fails if
`hostPort` is removed). The service itself was never affected, because it ignores
`task_definition` changes.

### Code and offline tests

| # | Check | Result |
|---|---|---|
| P5-1 | `scripts/app_deploy.sh` (`test_app_deploy.py`, stubbed AWS CLI): digest-only input, refused before any AWS call otherwise; account guard; image must be in ECR; never creates a missing service; only the image changes in the new revision (hardened settings, roles and tags verified); circuit-breaker rollback, timeout, wrong PRIMARY and zero healthy targets each fail the job | ✅ 15/15 |
| P5-2 | `scripts/push_image.sh` (`test_push_image.py`): immutable commit tag, digest published, a re-run never overwrites, registry password only via stdin | ✅ 4/4 |
| P5-3 | `scripts/tf_ci.sh` additions: the initial image is composed from this account + the manifest and must be `sha256:<64 hex>`; a plan that deletes or replaces the running ECS service is refused (plan and apply); task-definition replacement still allowed | ✅ 12 new (23/23 total) |
| P5-4 | Workflow rules: image pushed only after smoke test + Trivy gate (step order); image-build is the only AWS job without an environment (push to `main` only, push role); app-deploy requires a digest and `dev-deploy`; Terraform workflows pass only `SERVICE_IMAGE_DIGEST` | ✅ 5 new rules + 14 generic cases for the 2 new workflows |
| P5-5 | Mutation testing: rollout state, PRIMARY check, target-health check, image-only change, service existence, digest format, service-delete guard each removed in turn | ✅ 7/7 caught |
| P5-6 | Ruff · Bandit · actionlint · zizmor · shellcheck · Checkov `github_actions` + `secrets` | ✅ clean · Checkov 298 passed, 0 failed |

**Defect found while building Phase 5 (and fixed):** the rollout timer started before the ECR and
ECS checks, so on a slow runner the wait loop could end without polling even once. It showed up as
a flaky timeout test. The timer now starts at `update-service`, and the loop always polls at
least once.

**Defect found in AWS (and fixed): identifying values in public logs.** Reading the first
service plan log (run 45127566917) showed the operator's IP (`ALLOWED_INGRESS_CIDR`) and the
account ID (role ARNs, state bucket) in clear text. They were GitHub *variables*, and every step
echoes the job's `env`. `mask-aws-account-id` only masks after the credentials step. The Phase 4
plan/apply logs had the same problem. Fix: these values are now *secrets*, which GitHub masks from
the first line. The configuration script deletes the old variables. A hygiene test allows only
`AWS_REGION` and `SERVICE_IMAGE_DIGEST` as variables, and it fails if the IP is moved back.
With the owner's approval, the logs of the 8 affected runs were deleted on 2026-11-23 around
07:30 UTC: plan 45115730322, 45118508549, 45120116740, 45121998148, 45127566917; apply 45116102618,
45121248014; image-build 45126795712. The API returns 404 for them now. The runs, results and summaries
remain, and their evidence is recorded in this file. Verified: the first run after the fix
(45130666726) printed no identifying value.

**Design decisions:**
- The runner does not probe `/health`, because the ALB admits only the operator /32 (SE-2). Verification is the
  deployment's own `rolloutState` (not "services-stable", which also passes after a rollback),
  the PRIMARY revision, and ALB target health, which probes `/health`.
- ECR's scan on push is reported, not gated: it also lists vulnerabilities with no fix yet. The
  gate is Trivy before the push.

## Phase 4 — Dev infrastructure (2026-11-23)

### AWS apply (☁️ AWS-verified)

Run through GitHub Actions with OIDC from `main`; the apply was approved by the owner in the `dev`
environment. Account ID masked in the logs.

| # | Step | Evidence | Result |
|---|---|---|---|
| P4-A1 | `terraform-plan` run [45120116740](https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/actions/runs/45120116740) | `Plan: 37 to add, 0 to change, 0 to destroy.` Matches the expected count (network 18, load balancer 4, cluster 2, observability 13; no service, because no image exists yet) | ✅ |
| P4-A2 | `terraform-apply` run [45121248014](https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/actions/runs/45121248014), 06:02–06:05 | Reviewed digest `76bb2470…a76ee` re-computed and matched; `Apply complete! Resources: 37 added, 0 changed, 0 destroyed.` | ✅ |
| P4-A3 | Outputs | ALB `idp-dev-216884465.us-east-2.elb.amazonaws.com`, cluster and dashboard `idp-dev`, log group `/aws/events/idp-dev/ecs-deployments`, `service_deployed = false` | ✅ |
| P4-A4 | SNS alert subscription | Confirmed by the owner from the e-mail | ✅ |
| P4-A5 | Drift check: `terraform-plan` run [45121998148](https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/actions/runs/45121998148), 06:07:32–06:07:52 | `No changes. Your infrastructure matches the configuration.` | ✅ |
| P4-A6 | ALB reachability from the sandbox (not the allowed /32) | Connection timed out. Consistent with the security group, but **not proof** of correct behaviour | ⚠️ inconclusive |
| P4-A6b | CloudWatch alarms in the console (owner screenshot, ~06:12) | 4 alarms (`idp-dev-latency-p95`, `-target-5xx`, `-alb-5xx`, `-unhealthy-targets`): all `OK`, 0 in alarm, 0 insufficient data | ✅ |
| P4-A7 | ALB `/health` from the operator's allowed IP in a browser (owner screenshot, ~06:15) | `503 Service Temporarily Unavailable`, as expected: the listener answers, and there are no targets until Phase 5 | ✅ |

### Code and offline tests

| # | Check | Result |
|---|---|---|
| P4-1 | Module tests: network 4, load-balancer 3, ecs-cluster 2, ecs-service 10, observability 3 | ✅ 22/22 |
| P4-2 | Stack guardrail tests (now with the full environment wiring) | ✅ 19/19; env data dev/staging/prod ✅ |
| P4-3 | `scripts/tf_ci.sh` plan-digest gate (`test_tf_ci.py`) | ✅ 11/11 |
| P4-4 | Mutation testing of the gate: digest comparison removed; plan-document check removed | ✅ both caught. A third check was proven unreachable (dead code) and removed |
| P4-5 | Workflow hygiene: AWS jobs need a protected environment, `main` only, manual triggers, masked account ID; apply requires the digest; no plan artifact | ✅ 47 hygiene tests |
| P4-6 | TFLint + AWS ruleset · Checkov · Trivy (all severities) · actionlint · zizmor · shellcheck | ✅ 0 issues · 0 failed (39 justified skips) · 0 findings · clean |

**Defects found while building Phase 4 (and fixed):**

| Defect | How it was found | Fix |
|---|---|---|
| **Fail-open digest gate:** if `terraform show -json` produced an empty document, both the reviewed plan and the apply would hash to the empty-input SHA-256 and match | A test of "drifted plan is refused" passed when it should have failed. The cause was a test-fixture path collision that emptied the plan JSON; it exposed that the script accepted it | `tf_ci.sh` refuses anything that is not a Terraform plan document (`format_version`); `test_fails_closed_on_a_non_plan_document` |
| A test edit was silently not applied (the formatter had reflowed the target text), so the fixture still lacked `format_version` | Unexpected failures after the fix | Every scripted edit now asserts that its anchor matched |
| The operator's home IP was written into the new runbook | Personal-data scan before commit | Replaced with a placeholder; new hygiene test fails on any public IPv4 CIDR in tracked files (proven to catch the address) |
| Checkov secret heuristic flagged a test fixture named `DB_PASSWORD` (a secret *name*, not a value) | Checkov | Fixture renamed to `DB_DSN`; the scanner is not suppressed |

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

**GitHub environments configured and verified** (owner, 2026-11-23): `scripts/configure_github_environments.sh`
created `dev-plan`, `dev` and `dev-deploy`. Then `scripts/verify_github_settings.sh` returned
`RESULT: all checks passed`:

```text
PASS     environment dev requires a reviewer
PASS     environment dev deploys only from main
PASS     environment dev-deploy requires a reviewer
PASS     environment dev-deploy deploys only from main
INFO     environment dev-plan: reviewers=0 branch policy=custom
PASS     environment dev-plan deploys only from main
```

(The `main` ruleset, secret scanning, Dependabot and Actions-token checks also still PASS. The OIDC
subject is unchanged: immutable prefix `repo:oteyami2001@157901928/Internal-Developer-Platform-CI-CD-Automation@1465573837`.)

**Bootstrap applied and AWS-verified ☁️** (owner, AWS CloudShell us-east-2, 2026-11-23):

- `terraform apply bootstrap.tfplan`: **`Apply complete! Resources: 28 added, 0 changed, 0 destroyed.`** (~05:21 UTC; the S3 lifecycle configurations took 56 s).
- Outputs match the design: four roles, each trusting exactly one immutable OIDC subject (`…@1465573837:environment:dev-plan`, `:environment:dev`, `:environment:dev-deploy`, `:ref:refs/heads/main`), boundary `idp-dev-workload-boundary`, ECR `idp/sample-api`, trail `idp-management-events`.
- State migrated to `s3://idp-tfstate-<account>-us-east-2/bootstrap/terraform.tfstate` (66,023 bytes, 05:31:42 UTC).
- `scripts/verify_bootstrap.sh` at **2026-11-23T05:31:48Z: `RESULT: all checks passed`** (20/20 PASS). Covered: state bucket versioning, SSE-KMS, public access block and TLS-only policy; trail logging with log file validation (first delivery 05:28:23Z); each role's exact subject and audience; boundary; ECR immutability and scan-on-push; project budget. The shared OIDC provider and the AIOps budget are untouched.

Runbook defects found on this first run, fixed in [bootstrap-runbook.md](bootstrap-runbook.md):
- The bucket name was read through `terraform output` after `backend.tf` existed, so it came out empty.
- A typed `yes` at the bucket-name prompt was taken as the bucket name.
- `-input=false` is refused for a state migration; `-force-copy` replaces it.

Each failed safely: the local state stayed intact until the migration succeeded. Record
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
| 1 | Developer creates a new service from a template | ✅ in CI on every PR: P6-1 (generated `orders-api` passes manifest, own tests 100% coverage, Ruff); PR #12 green |
| 2 | PR triggers tests and security scans | ✅ PR #1, runs 45096890726 (caught a real failure) and 45097129693 (green) |
| 3 | Insecure Terraform change fails validation | ✅ on GitHub: demo PR #17 (ECR tags `MUTABLE`) blocked by Terraform test, Checkov `CKV_AWS_51` and Trivy (run 45278084468); closed unmerged, reverted (P8-1) |
| 4 | Container image built and scanned | ✅ in CI on GitHub (run 45097129693, Trivy gate passed) |
| 5 | Approved image published to ECR | ☁️ P5-A1, P5-A7b |
| 6 | Authorized deployment updates ECS Fargate | ☁️ P5-A3 (first release), P5-A7, P5-A7c |
| 7 | Unapproved deployment is blocked | ☁️ P5-A8 (rejected: job never started, no credentials) |
| 8 | Application passes health checks | ☁️ `/health` → `{"status":"ok"}` through the ALB (P5-A4); ALB `HealthyHostCount` 1 (P5-A5); every app-deploy verifies healthy targets (P5-A7, P5-A7c) |
| 9 | Failing release is rolled back | ☁️ P7-A1 (circuit breaker, job failed as designed) |
| 10 | Configuration drift detected | ☁️ P7-A2 (issue #15, nothing changed, restored via reviewed apply) |
| 11 | CloudWatch records deployment and application events | ☁️ P8-3: deployment events (full drill timeline) + application log group with one stream per task; JSON log format ✅ locally (E13) |
| 12 | Cleanup removes billable workload resources | ☁️ P8-4 (47 destroyed, verified empty state and no load balancer) |
