#!/usr/bin/env bash
# Keep only UNSUPPRESSED results in a SARIF file before uploading it to GitHub code scanning.
#
# Checkov writes every inline `checkov:skip=<ID>:<justification>` into its SARIF as a result with
# a `suppressions` entry. GitHub code scanning still raises those as alerts and PR review threads,
# so each deliberate, justified exception reappears on every pull request (owner decision
# 2026-11-23, option 2). The exceptions stay visible where they are decided and reviewed: next to
# the code and in docs/security-model.md. Real (unsuppressed) findings are kept, so they still
# alert, and the Checkov job still fails on them (soft_fail: false).
#
# Usage: scripts/sarif_unsuppressed.sh <in.sarif> <out.sarif>
set -euo pipefail
in=${1:?usage: sarif_unsuppressed.sh <in.sarif> <out.sarif>}
out=${2:?usage: sarif_unsuppressed.sh <in.sarif> <out.sarif>}
jq '.runs |= map(.results |= map(select((.suppressions // []) | length == 0)))' "$in" >"$out"
kept=$(jq '[.runs[].results[]] | length' "$out")
dropped=$(( $(jq '[.runs[].results[]] | length' "$in") - kept ))
echo "SARIF: kept $kept unsuppressed result(s), dropped $dropped suppressed (inline-justified) result(s)"
