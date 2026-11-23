# GitHub repository settings (owner actions)

The CI code enforces nothing on its own unless the repository settings make it a merge gate. These
settings cannot be changed from the build environment, so the owner applies them. Then
`scripts/verify_github_settings.sh` **reads them back from the API**; the result is the evidence.

Status: 📋 to be applied by the owner, then verified (Phase 2 exit criterion).

> The `gh api -X …` commands below change settings and need owner credentials. In a Codespace,
> run `unset GITHUB_TOKEN && gh auth login` first (see §5).

## 1. Default branch

`main` exists (created 2026-11-23 from the approved Phase 0–1 commit `29fd8d6`). Make it the default:
**Settings → General → Default branch → `main`**, or:

```bash
gh api -X PATCH repos/oteyami2001/Internal-Developer-Platform-CI-CD-Automation -f default_branch=main
```

## 2. Code security (free for public repositories)

**Settings → Advanced Security** (named *Code security* in older UIs): enable **Secret scanning**,
**Push protection**, **Dependabot alerts**, **Dependabot security updates**.

```bash
gh api -X PATCH repos/oteyami2001/Internal-Developer-Platform-CI-CD-Automation --input - <<'EOF'
{"security_and_analysis": {
  "secret_scanning": {"status": "enabled"},
  "secret_scanning_push_protection": {"status": "enabled"},
  "dependabot_security_updates": {"status": "enabled"}}}
EOF
```

```bash
gh api -X PUT repos/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/vulnerability-alerts
```

## 3. GitHub Actions defaults

**Settings → Actions → General:**
- *Workflow permissions*: **Read repository contents and packages permissions**, with
  **Allow GitHub Actions to create and approve pull requests** unchecked.
- *Fork pull request workflows*: **Require approval for first-time contributors** (or for all outside collaborators).
- *Actions permissions*: if offered, enable **Require actions to be pinned to a full-length commit SHA**
  (CI already passes this; `tests/platform/test_repo_hygiene.py` enforces it in code as well).

```bash
gh api -X PUT repos/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
```

## 4. Branch ruleset for `main`

Definition: [`.github/rulesets/main.json`](../.github/rulesets/main.json). It blocks deletion and
force pushes, requires a pull request with resolved review threads, and requires the `ci-ok`
status check from GitHub Actions on an up-to-date branch. No bypass actors.

```bash
gh api -X POST repos/oteyami2001/Internal-Developer-Platform-CI-CD-Automation/rulesets \
  --input .github/rulesets/main.json
```

**Why `required_approving_review_count` is 0 and code-owner review is off:** GitHub never lets an
author approve their own PR. With a single maintainer, requiring 1 approval or code-owner review
would make `main` unmergeable without a bypass, and a standing bypass is worse than an honest
setting. CODEOWNERS is still in place. When a second maintainer joins, set the count to 1 and
`require_code_owner_review` to true (exception SE-5).

## 5. Verify (read-only)

Run from a local clone or a Codespace, signed in to `gh` **as the repository owner**:

```bash
scripts/verify_github_settings.sh
```

**In a GitHub Codespace**, `gh` uses the Codespace's `GITHUB_TOKEN`, which cannot read security
settings (they show as `UNKNOWN`) and cannot change them. Sign in as yourself first, in the same terminal:

```bash
unset GITHUB_TOKEN && gh auth login
```

The script exits 0 only when every control is a verified `PASS`. `UNKNOWN` means "not readable
with this token", not "OK".

Expected after steps 1–4: `RESULT: all checks passed`. Code-owner review is reported as `INFO`
(SE-5). The output also prints the **repository ID** and **OIDC subject format** that Phase 3
needs for exact trust policies. Paste the output into `docs/portfolio-evidence.md` (Phase 2
section) or share it for me to record.

## 6. Deployment environments (Phase 3, not now)

`dev-plan`, `dev` and `dev-deploy` are created in Phase 3, with **required reviewers** on `dev` and
`dev-deploy` and **deployment branches limited to `main`** on all three. The same script verifies them.
