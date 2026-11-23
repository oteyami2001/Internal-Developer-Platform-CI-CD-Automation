#!/usr/bin/env bash
# Open, or comment on, the single open drift issue of an environment (drift-detection.yml).
#
#   report_drift.sh <env> <report.md>
#
# One open issue per environment ("Drift detected: <env>", label `drift`): a weekly run comments on
# it instead of opening duplicates. The report holds resource addresses and actions only.
# Requires GH_TOKEN (issues: write) and GH_REPO.
set -euo pipefail

ENV=${1:?usage: report_drift.sh <env> <report.md>}
REPORT=${2:?usage: report_drift.sh <env> <report.md>}
case "$ENV" in dev | staging | prod) ;; *) echo "unknown environment: $ENV" >&2; exit 2 ;; esac
[ -s "$REPORT" ] || { echo "::error::drift report $REPORT is missing or empty"; exit 2; }
TITLE="Drift detected: $ENV"

gh label create drift --color B60205 --description "Real infrastructure differs from the code" --force >/dev/null
existing=$(gh issue list --label drift --state open --json number,title \
  --jq "[.[] | select(.title == \"$TITLE\")][0].number // empty")

if [ -n "$existing" ]; then
  gh issue comment "$existing" --body-file "$REPORT" >/dev/null
  echo "Updated drift issue #$existing"
else
  url=$(gh issue create --title "$TITLE" --label drift --body-file "$REPORT")
  echo "Opened drift issue: $url"
fi
