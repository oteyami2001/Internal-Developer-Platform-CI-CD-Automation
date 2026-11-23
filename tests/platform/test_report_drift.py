"""scripts/report_drift.sh: one open drift issue per environment; later runs comment on it."""

import os
import subprocess

import pytest
from validate_service import ROOT

SCRIPT = ROOT / "scripts" / "report_drift.sh"

GH_STUB = """#!/usr/bin/env bash
echo "gh $*" >>"$STUB_DIR/calls.log"
case "$1 $2" in
  "label create") exit 0 ;;
  "issue list") [ -n "${STUB_OPEN_ISSUE:-}" ] && echo "$STUB_OPEN_ISSUE"; exit 0 ;;
  "issue comment") exit 0 ;;
  "issue create") echo "https://github.com/o/r/issues/7" ;;
  *) exit 1 ;;
esac
"""


@pytest.fixture
def run(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(GH_STUB)
    (bin_dir / "gh").chmod(0o755)
    report = tmp_path / "drift.md"
    report.write_text("| update | `module.observability.aws_cloudwatch_metric_alarm.latency_p95` |\n")

    def _run(env_name="dev", report_path=report, **extra):
        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}", "STUB_DIR": str(tmp_path), **extra}
        cmd = ["bash", str(SCRIPT), env_name, str(report_path)]
        result = subprocess.run(cmd, env=env, capture_output=True, text=True, check=False)  # noqa: S603 - fixed argv
        calls = (tmp_path / "calls.log").read_text() if (tmp_path / "calls.log").exists() else ""
        return result, calls

    _run.dir = tmp_path
    return _run


def test_opens_a_labelled_issue_when_none_is_open(run):
    result, calls = run()
    assert result.returncode == 0, result.stderr
    assert "gh label create drift" in calls
    assert "gh issue create --title Drift detected: dev --label drift --body-file" in calls
    assert "Opened drift issue" in result.stdout


def test_comments_on_the_open_issue_instead_of_duplicating(run):
    result, calls = run(STUB_OPEN_ISSUE="42")
    assert result.returncode == 0, result.stderr
    assert "gh issue comment 42 --body-file" in calls
    assert "issue create" not in calls


def test_refuses_unknown_environment_and_missing_report(run):
    assert run(env_name="qa")[0].returncode == 2
    assert run(report_path=run.dir / "missing.md")[0].returncode == 2
