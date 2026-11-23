#!/usr/bin/env bash
# Verify the repository's GitHub security settings - READ-ONLY (GET requests only).
#
# "An environment/branch rule exists" is not the same as "it is enforced". This script reads the
# live settings through the GitHub API and prints PASS/FAIL per control, so the evidence in
# docs/portfolio-evidence.md comes from the API, not from assumptions.
#
# Usage:  scripts/verify_github_settings.sh [owner/repo]
# Needs:  gh (authenticated: `gh auth login`), jq
set -uo pipefail

REPO=${1:-oteyami2001/Internal-Developer-Platform-CI-CD-Automation}
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
info() { printf 'INFO  %s\n' "$1"; }
api() { gh api -H "Accept: application/vnd.github+json" "$@" 2>/dev/null; }

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

echo "# GitHub settings verification for $REPO ($(date -u +%Y-%m-%dT%H:%M:%SZ))"

repo_json=$(api "repos/$REPO") || { echo "cannot read repos/$REPO" >&2; exit 2; }
info "repository id: $(jq -r .id <<<"$repo_json") (needed for immutable OIDC subjects, Phase 3)"
info "visibility: $(jq -r .visibility <<<"$repo_json")"

[ "$(jq -r .default_branch <<<"$repo_json")" = "main" ] \
  && pass "default branch is main" || fail "default branch is $(jq -r .default_branch <<<"$repo_json") (expected main)"

# --- Secret scanning (free for public repositories) ---
ss=$(jq -r '.security_and_analysis.secret_scanning.status // "unknown"' <<<"$repo_json")
pp=$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unknown"' <<<"$repo_json")
[ "$ss" = "enabled" ] && pass "secret scanning enabled" || fail "secret scanning: $ss"
[ "$pp" = "enabled" ] && pass "secret scanning push protection enabled" || fail "push protection: $pp"

# --- Dependabot ---
if gh api "repos/$REPO/vulnerability-alerts" --silent 2>/dev/null; then
  pass "Dependabot alerts enabled"
else
  fail "Dependabot alerts disabled"
fi
dsu=$(jq -r '.security_and_analysis.dependabot_security_updates.status // "unknown"' <<<"$repo_json")
[ "$dsu" = "enabled" ] && pass "Dependabot security updates enabled" || fail "Dependabot security updates: $dsu"

# --- Actions defaults ---
wp=$(api "repos/$REPO/actions/permissions/workflow")
[ "$(jq -r .default_workflow_permissions <<<"$wp")" = "read" ] \
  && pass "default GITHUB_TOKEN permissions are read-only" || fail "default GITHUB_TOKEN permissions: $(jq -r .default_workflow_permissions <<<"$wp")"
[ "$(jq -r .can_approve_pull_request_reviews <<<"$wp")" = "false" ] \
  && pass "Actions cannot approve pull requests" || fail "Actions can approve pull requests"
fork=$(api "repos/$REPO/actions/permissions/fork-pr-contributor-approval" | jq -r '.approval_policy // "unknown"')
info "fork PR workflow approval policy: $fork (recommended: first_time_contributors or all_external_contributors)"

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
  [ "$branch_policy" != "none" ] && pass "environment $e restricts deployment branches ($branch_policy)" || fail "environment $e allows any branch"
done

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: $fails check(s) failed"; fi
exit $(( fails > 0 ))
