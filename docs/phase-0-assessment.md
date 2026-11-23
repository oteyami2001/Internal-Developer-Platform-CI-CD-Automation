# Phase 0 — Repository and environment assessment

Date: 2026-11-23 (UTC). Read-only inspection; nothing was changed in GitHub or AWS.

## 1. Repository assessment

| Item | Finding |
|---|---|
| Repository | `oteyami2001/Internal-Developer-Platform-CI-CD-Automation`, **public** |
| Branches on GitHub | **None**: the repository has no commits (GitHub API `list_branches` returned `[]`, `git ls-remote` returned no refs) |
| Default branch | Not yet created (it appears with the first push) |
| Pull requests | None (open or closed) |
| Workflows, Terraform, application code, README, tests, security checks | None |
| Local working copy | Branch `claude/stoic-volta-i07auh`, no commits, clean tree |

**Conclusion:** there is no existing work to preserve or conflict with. Phase 1 adds only new
files, on the feature branch `claude/stoic-volta-i07auh`. Because the repository is empty, the
first push of this branch will become the repository's only branch until `main` is created.
Creating `main` (and branch protection) is an owner decision for Phase 2.

## 2. Reference project review (`oteyami2001/AWS-Cloud-Operations-AI-Automation`)

Read (shallow clone) for engineering practices. Nothing was copied wholesale.

| Practice | Adopted? | Notes |
|---|---|---|
| OIDC roles split plan / apply / image-push with exact `sub` | ✅ adopted, extended | Adds a separate **deploy** role for application releases |
| Plan role trusting `pull_request` | ❌ changed | See ADR 0003: a same-repo PR can rewrite the workflow and use that trust |
| Apply of the saved plan artifact | ✅ adopted, hardened | Adds SHA-256 and commit-SHA verification, plus stale-approval protection |
| Permissions boundary required for every created role | ✅ adopted | |
| Native S3 lock files (`use_lockfile`) | ✅ adopted | |
| `defaults.run.shell: bash` (pipefail) after a green-but-failed plan | ✅ adopted | Hit again in this phase with a background build |
| SHA-pinned actions, Checkov hard-fail with inline justified skips | ✅ adopted (Phase 2) | |
| Mutable `image_tag` deploy input | ❌ changed | Digests only, validated in Terraform |
| Region decision record (SCP blocked us-east-1) | ✅ informs our proposal | Not assumed: the target account and Region still need confirmation |

## 3. AWS environment assessment

**Blocked.** The build environment's AWS credentials are a placeholder (`InvalidClientTokenId`
from STS), so no read-only discovery ran. Run `scripts/aws_discovery.sh` and see
[deployment-plan.md §1](deployment-plan.md#1-phase-0--aws-environment-assessment-2026-11-23).

## 4. Tooling available for validation

| Tool | Available | Notes |
|---|---|---|
| Python 3.13, pytest, Ruff, Bandit | ✅ | |
| Terraform 1.17.2 | ✅ | Installed from releases.hashicorp.com with SHA-256 verification. The public registry is blocked here, so providers came from a local checksum-verified mirror |
| Docker | ✅ | Behind a TLS-intercepting proxy; Debian mirrors blocked (see portfolio-evidence.md) |
| Checkov 3.4.6 | ✅ | Online guideline download blocked (cosmetic) |
| Trivy | ✅ via container image | |
| TFLint | ❌ | GitHub release downloads blocked; runs in CI (Phase 2) |
| AWS CLI | ✅ installed, ❌ no valid credentials | |
