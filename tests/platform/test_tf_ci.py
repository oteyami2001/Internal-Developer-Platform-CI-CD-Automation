"""scripts/tf_ci.sh: the plan-digest gate that makes terraform-apply apply exactly the reviewed plan.

`aws` and `terraform` are replaced by stubs on PATH; the real manifest renderer and jq run.
"""

import json
import os
import shutil
import subprocess

import pytest
from validate_service import ROOT

SCRIPT = ROOT / "scripts" / "tf_ci.sh"
ACCOUNT = "111111111111"

PLAN = {
    "format_version": "1.2",  # what real `terraform show -json` emits; the script requires it
    "resource_changes": [
        {
            "address": "module.network.aws_vpc.this",
            "change": {"actions": ["create"], "after": {"cidr_block": "10.40.0.0/20"}, "after_unknown": {"id": True}},
        },
        {
            "address": "module.ecs_cluster.aws_ecs_cluster.this",
            "change": {"actions": ["create"], "after": {"name": "idp-dev"}, "after_unknown": {}},
        },
        {"address": "data.aws_region.current", "change": {"actions": ["no-op"], "after": {}, "after_unknown": {}}},
    ],
}

TERRAFORM_STUB = """#!/usr/bin/env bash
case "$1" in
  -chdir=*) shift ;;
esac
case "$1" in
  init) exit 0 ;;
  plan) echo "Plan: 2 to add, 0 to change, 0 to destroy."; exit 2 ;;
  show) cat "$STUB_PLAN_JSON" ;;
  apply) touch "$STUB_DIR/applied"; echo "Apply complete! Resources: 2 added, 0 changed, 0 destroyed." ;;
  output) echo 'service_url = "http://idp-dev.example"'; echo 'account_id = "111111111111"' ;;
  *) exit 1 ;;
esac
"""

AWS_STUB = """#!/usr/bin/env bash
[ "$1 $2" = "sts get-caller-identity" ] && echo "$STUB_CALLER_ACCOUNT" && exit 0
exit 1
"""


@pytest.fixture
def stub(tmp_path):
    if not shutil.which("jq"):
        pytest.skip("jq not installed")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in {"terraform": TERRAFORM_STUB, "aws": AWS_STUB}.items():
        path = bin_dir / name
        path.write_text(body)
        path.chmod(0o755)
    plan_json = tmp_path / "stub-plan.json"  # NOT $RUNNER_TEMP/plan.json, which the script writes
    plan_json.write_text(json.dumps(PLAN))

    def run(cmd: str, plan: dict | None = None, **overrides: str) -> subprocess.CompletedProcess:
        if plan is not None:
            plan_json.write_text(json.dumps(plan))
        env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(tmp_path),
            "RUNNER_TEMP": str(tmp_path),
            "GITHUB_STEP_SUMMARY": str(tmp_path / "summary.md"),
            "GITHUB_OUTPUT": str(tmp_path / "output"),
            "STUB_DIR": str(tmp_path),
            "STUB_PLAN_JSON": str(plan_json),
            "STUB_CALLER_ACCOUNT": ACCOUNT,
            "AWS_ROLE_ARN": f"arn:aws:iam::{ACCOUNT}:role/idp-dev-github-plan",
            "AWS_REGION": "us-east-2",
            "TF_STATE_BUCKET": f"idp-tfstate-{ACCOUNT}-us-east-2",
            "ALLOWED_INGRESS_CIDR": "203.0.113.10/32",
            "TF_VAR_alert_email": "alerts@example.com",
            **overrides,
        }
        return subprocess.run(["bash", str(SCRIPT), cmd, "dev"], env=env, capture_output=True, text=True, check=False)  # noqa: S603, S607

    run.dir = tmp_path
    return run


def plan_digest(stub) -> str:
    result = stub("plan")
    assert result.returncode == 0, result.stderr + result.stdout
    output = (stub.dir / "output").read_text()
    digest = output.strip().split("digest=")[1]
    assert len(digest) == 64
    return digest


def test_plan_publishes_digest_and_reviewable_summary(stub):
    digest = plan_digest(stub)
    summary = (stub.dir / "summary.md").read_text()
    assert digest in summary
    assert "Plan: 2 to add, 0 to change, 0 to destroy." in summary
    assert "`module.network.aws_vpc.this`" in summary
    assert "data.aws_region.current" not in summary  # no-ops are not listed
    assert "alerts@example.com" not in summary and "203.0.113.10" not in summary


def test_apply_runs_only_with_the_reviewed_digest(stub):
    digest = plan_digest(stub)
    result = stub("apply", EXPECTED_DIGEST=digest)
    assert result.returncode == 0, result.stderr + result.stdout
    assert (stub.dir / "applied").exists()
    summary = (stub.dir / "summary.md").read_text()
    assert "service_url" in summary and "account_id" not in summary.split("### Outputs")[1]


def test_apply_refuses_when_the_plan_changed_after_review(stub):
    digest = plan_digest(stub)
    drifted = json.loads(json.dumps(PLAN))
    drifted["resource_changes"][0]["change"]["after"]["cidr_block"] = "10.99.0.0/20"
    result = stub("apply", plan=drifted, EXPECTED_DIGEST=digest)
    assert result.returncode == 1
    assert "Refusing to apply" in result.stdout
    assert not (stub.dir / "applied").exists()


def test_digest_ignores_resource_order(stub):
    digest = plan_digest(stub)
    reordered = {**PLAN, "resource_changes": list(reversed(PLAN["resource_changes"]))}
    result = stub("apply", plan=reordered, EXPECTED_DIGEST=digest)
    assert result.returncode == 0, result.stdout


def test_apply_rejects_malformed_digest(stub):
    result = stub("apply", EXPECTED_DIGEST="not-a-digest")
    assert result.returncode == 2
    assert not (stub.dir / "applied").exists()


def test_refuses_credentials_for_another_account(stub):
    result = stub("plan", STUB_CALLER_ACCOUNT="222222222222")
    assert result.returncode == 1
    assert "another account" in result.stdout


def test_refuses_missing_configuration(stub):
    result = stub("plan", ALLOWED_INGRESS_CIDR="")
    assert result.returncode == 2
    assert "ALLOWED_INGRESS_CIDR is not set" in result.stdout


def test_cli_rejects_unknown_environment(stub):
    result = subprocess.run(["bash", str(SCRIPT), "plan", "qa"], capture_output=True, text=True, check=False)  # noqa: S603, S607
    assert result.returncode == 2


@pytest.mark.parametrize("bad_plan", [{}, {"resource_changes": []}, []])
def test_fails_closed_on_a_non_plan_document(stub, bad_plan):
    """An empty/foreign document must never produce a digest (it would always match)."""
    result = stub("plan", plan=bad_plan)
    assert result.returncode == 1
    assert "did not produce a plan document" in result.stdout
    empty_input_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    result = stub("apply", plan=bad_plan, EXPECTED_DIGEST=empty_input_sha256)
    assert result.returncode == 1
    assert not (stub.dir / "applied").exists()
