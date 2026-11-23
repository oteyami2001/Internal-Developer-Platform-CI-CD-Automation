#!/usr/bin/env bash
# Verify the repository's GitHub security settings - READ-ONLY (GET requests only).
#
# "An environment/branch rule exists" is not the same as "it is enforced". This script reads the
# live settings through the GitHub API and prints PASS/FAIL per control, so the evidence in
# docs/portfolio-evidence.md comes from the API, not from assumptions.
#
# Usage:  scripts/verify_github_settings.sh [owner/repo]
# Needs:  gh authenticated AS THE REPOSITORY OWNER (`gh auth login`), jq.
#         In a GitHub Codespace, gh uses the Codespace's GITHUB_TOKEN, which cannot read most
#         security settings. Run `unset GITHUB_TOKEN && gh auth login` first.
# Exit:   0 only if every control is verified PASS. FAIL = verified wrong; UNKNOWN = not readable
#         with this token (not verified, so it also makes the script exit non-zero).
set -uo pipefail

REPO=${1:-oteyami2001/Internal-Developer-Platform-CI-CD-Automation}
fails=0
unknowns=0
pass() { printf 'PASS     %s\n' "$1"; }
fail() { printf 'FAIL     %s\n' "$1"; fails=$((fails + 1)); }
unknown() { printf 'UNKNOWN  %s (this token cannot read it)\n' "$1"; unknowns=$((unknowns + 1)); }
info() { printf 'INFO     %s\n' "$1"; }
# check <label> <actual> <expected>: PASS/FAIL when readable, UNKNOWN when the API returned nothing.
check() {
  case "$2" in
    "" | null | unknown) unknown "$1" ;;
    "$3") pass "$1" ;;
    *) fail "$1 (is: $2, expected: $3)" ;;
  esac
}
api() { gh api -H "Accept: application/vnd.github+json" "$@" 2>/dev/null; }

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

echo "# GitHub settings verification for $REPO ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  info "GITHUB_TOKEN is set, so gh uses it instead of your login. In a Codespace that token cannot read"
  info "security settings: run 'unset GITHUB_TOKEN && gh auth login', then re-run this script."
fi

repo_json=$(api "repos/$REPO") || { echo "cannot read repos/$REPO" >&2; exit 2; }
info "repository id: $(jq -r .id <<<"$repo_json") (needed for immutable OIDC subjects, Phase 3)"
info "visibility: $(jq -r .visibility <<<"$repo_json")"

check "default branch" "$(jq -r .default_branch <<<"$repo_json")" main

# --- Secret scanning (free for public repositories). security_and_analysis is only returned to admins. ---
check "secret scanning" "$(jq -r '.security_and_analysis.secret_scanning.status // ""' <<<"$repo_json")" enabled
check "secret scanning push protection" "$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // ""' <<<"$repo_json")" enabled

# --- Dependabot: 204 = enabled, 404 = disabled, anything else (e.g. 403) = not readable ---
va_err=$(gh api "repos/$REPO/vulnerability-alerts" --silent 2>&1)
if [ -z "$va_err" ]; then
  pass "Dependabot alerts"
elif grep -q "HTTP 404" <<<"$va_err"; then
  fail "Dependabot alerts (disabled)"
else
  unknown "Dependabot alerts"
fi
check "Dependabot security updates" "$(jq -r '.security_and_analysis.dependabot_security_updates.status // ""' <<<"$repo_json")" enabled

# --- Actions defaults ---
wp=$(api "repos/$REPO/actions/permissions/workflow")
[ -n "$wp" ] || wp='{}'
check "default GITHUB_TOKEN permissions" "$(jq -r '.default_workflow_permissions // ""' <<<"$wp")" read
check "Actions cannot approve pull requests (can_approve_pull_request_reviews)" "$(jq -r 'if has("can_approve_pull_request_reviews") then (.can_approve_pull_request_reviews | tostring) else "" end' <<<"$wp")" false
fork=$(api "repos/$REPO/actions/permissions/fork-pr-contributor-approval" | jq -r '.approval_policy // "unknown"' 2>/dev/null)
info "fork PR workflow approval policy: ${fork:-unknown} (recommended: first_time_contributors or all_external_contributors)"

# --- Branch ruleset on main ---
rules=$(api "repos/$REPO/rules/branches/main")
if [ -z "$rules" ] || [ "$(jq 'length' <<<"$rules")" = "0" ]; then
  fail "no active rules on main (apply .github/rulesets/main.json)"
else
  jq -e 'any(.[]; .type == "pull_request")' <<<"$rules" >/dev/null && pass "main requires a pull request" || fail "main does not require a pull request"
  jq -e 'any(.[]; .type == "non_fast_forward")' <<<"$rules" >/dev/null && pass "force pushes to main blocked" || fail "force pushes to main allowed"
  jq -e 'any(.[]; .type == "deletion")' <<<"$rules" >/dev/null && pass "deletion of main blocked" || fail "main can be deleted"
  jq -e 'any(.[]; .type == "required_status_checks" and any(.parameters.required_status_checks[]; .context == "ci-ok"))' <<<"$rules" >/dev/null \
    && pass "status check ci-ok required on main" || fail "ci-ok is not a required status check"
  jq -e 'any(.[]; .type == "pull_request" and .parameters.require_code_owner_review == true)' <<<"$rules" >/dev/null \
    && pass "code-owner review required" \
    || info "code-owner review NOT required (expected while the project has a single maintainer - SE-5)"
fi

# --- OIDC subject format (input for Phase 3 trust policies) ---
sub=$(api "repos/$REPO/actions/oidc/customization/sub")
info "OIDC subject customization: ${sub:-<default>}"

# --- Deployment environments (Phase 3 configures these) ---
envs=$(api "repos/$REPO/environments" | jq -r '.environments[]?.name' | tr '\n' ' ')
info "environments: ${envs:-<none>}"
for e in $envs; do
  ej=$(api "repos/$REPO/environments/$e")
  reviewers=$(jq '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?] | length' <<<"$ej")
  branch_policy=$(jq -r '.deployment_branch_policy // "none" | if type == "object" then (if .protected_branches then "protected branches" else "custom" end) else . end' <<<"$ej")
  if [ "$e" = "dev-plan" ]; then
    info "environment $e: reviewers=$reviewers branch policy=$branch_policy"
  else
    [ "$reviewers" -ge 1 ] && pass "environment $e requires a reviewer" || fail "environment $e has NO required reviewer"
  fi
  if [ "$branch_policy" = "custom" ]; then
    allowed=$(api "repos/$REPO/environments/$e/deployment-branch-policies" | jq -r '[.branch_policies[]?.name] | sort | join(",")')
    check "environment $e deploys only from main" "$allowed" main
  elif [ "$branch_policy" = "none" ]; then
    fail "environment $e allows any branch"
  else
    pass "environment $e restricts deployment branches ($branch_policy)"
  fi
done

echo
if [ "$fails" -eq 0 ] && [ "$unknowns" -eq 0 ]; then
  echo "RESULT: all checks passed"
else
  echo "RESULT: $fails failed, $unknowns not verifiable with this token"
fi
exit $(( fails + unknowns > 0 ))
