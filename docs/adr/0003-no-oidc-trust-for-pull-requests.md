# ADR 0003: No AWS role is assumable from pull requests

- **Status:** Accepted (Phase 1 proposal)
- **Date:** 2026-11-23

## Context
In the previous project, the read-only plan role trusted the OIDC subject
`repo:<owner>/<repo>:pull_request`. Any same-repository PR branch can modify a workflow file in
that PR, and the modified workflow runs with that trust. "Read-only" still includes reading
Terraform state, which can contain sensitive values, and describing the whole account.

## Decision
- `ci.yml` (all PRs) runs with **no AWS credentials** and only offline checks: mocked-provider
  `terraform test`, validate, Checkov, Trivy.
- Every AWS role trusts an exact subject naming a **GitHub environment** (`dev-plan`, `dev`,
  `dev-deploy`) or `refs/heads/main` (image push only). Those environments allow deployments from
  `main` only, so a PR ref cannot obtain a token with a matching subject.
- OIDC trust uses `StringEquals` on both `aud` and `sub`; no wildcards.

## Consequences
- Reviewers do not see a live AWS plan on the PR itself. They see offline validation; the live
  plan runs right after merge, and nothing is applied without a second approval.
- If live PR plans become necessary, add a `pr-plan` environment with a **required reviewer**,
  so a human approves each run before a token is issued.
