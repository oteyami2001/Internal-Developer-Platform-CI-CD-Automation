"""scripts/sarif_unsuppressed.sh: only real findings reach GitHub code scanning (owner decision, option 2)."""

import json
import shutil
import subprocess

import pytest
from validate_service import ROOT

SCRIPT = ROOT / "scripts" / "sarif_unsuppressed.sh"


def result(rule: str, suppressed: bool) -> dict:
    r = {"ruleId": rule, "message": {"text": rule}, "locations": []}
    if suppressed:
        r["suppressions"] = [{"kind": "inSource", "justification": "documented exception"}]
    return r


@pytest.fixture
def sarif(tmp_path):
    if not shutil.which("jq"):
        pytest.skip("jq not installed")
    doc = {
        "version": "2.1.0",
        "runs": [
            {
                "tool": {"driver": {"name": "Checkov", "rules": [{"id": "CKV_AWS_1"}, {"id": "CKV_AWS_2"}]}},
                "results": [result("CKV_AWS_1", suppressed=True), result("CKV_AWS_2", suppressed=False)],
            }
        ],
    }
    src = tmp_path / "in.sarif"
    src.write_text(json.dumps(doc))
    return src, tmp_path / "out.sarif"


def run(src, dst):
    return subprocess.run(["bash", str(SCRIPT), str(src), str(dst)], capture_output=True, text=True, check=True)  # noqa: S603, S607


def test_drops_only_suppressed_results(sarif):
    src, dst = sarif
    out = run(src, dst)
    results = json.loads(dst.read_text())["runs"][0]["results"]
    assert [r["ruleId"] for r in results] == ["CKV_AWS_2"], "the real (unsuppressed) finding must still be uploaded"
    assert "kept 1 unsuppressed" in out.stdout and "dropped 1 suppressed" in out.stdout


def test_keeps_tool_and_rule_metadata(sarif):
    src, dst = sarif
    run(src, dst)
    doc = json.loads(dst.read_text())
    assert doc["version"] == "2.1.0"
    assert doc["runs"][0]["tool"]["driver"]["name"] == "Checkov"
    assert len(doc["runs"][0]["tool"]["driver"]["rules"]) == 2


def test_ci_uploads_only_the_filtered_report():
    text = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    assert "scripts/sarif_unsuppressed.sh checkov.sarif checkov-unsuppressed.sarif" in text
    assert "sarif_file: checkov-unsuppressed.sarif" in text
    assert "sarif_file: checkov.sarif" not in text, "the unfiltered report must not be uploaded"
