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
  plan)
    printf %s "${TF_VAR_service_image:-}" >"$STUB_DIR/service_image"
    echo "$*" >"$STUB_DIR/plan_args"
    echo "Plan: 2 to add, 0 to change, 0 to destroy."; exit "${STUB_PLAN_RC:-2}" ;;
  state) printf '%s' "${STUB_STATE:-}" ;;
  show) cat "$STUB_PLAN_JSON" ;;
  apply) touch "$STUB_DIR/applied"; echo "Apply complete! Resources: 2 added, 0 changed, 0 destroyed." ;;
  output) echo 'service_url = "http://idp-dev.example"'; echo 'account_id = "111111111111"' ;;
  *) exit 1 ;;
esac
"""

AWS_STUB = """#!/usr/bin/env bash
[ "$1 $2" = "sts get-caller-identity" ] && echo "$STUB_CALLER_ACCOUNT" && exit 0
[ "$1 $2" = "elbv2 describe-load-balancers" ] && exit "${STUB_ELB_RC:-254}"
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
        env = {k: v for k, v in env.items() if v is not None}
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


# --- Initial image and the "never delete the running service" guard ---------------------------
DIGEST = "sha256:" + "ab" * 32


def test_initial_image_is_composed_from_this_account_and_the_manifest(stub):
    result = stub("plan", SERVICE_IMAGE_DIGEST=DIGEST)
    assert result.returncode == 0, result.stdout
    assert (
        stub.dir / "service_image"
    ).read_text() == f"{ACCOUNT}.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api@{DIGEST}"


def test_no_initial_image_means_infrastructure_only(stub):
    assert stub("plan").returncode == 0
    assert (stub.dir / "service_image").read_text() == ""


@pytest.mark.parametrize("bad", ["latest", "sha256:" + "AB" * 32, "sha256:abc", DIGEST + "0"])
def test_initial_image_must_be_a_digest(stub, bad):
    result = stub("plan", SERVICE_IMAGE_DIGEST=bad)
    assert result.returncode == 2
    assert "SERVICE_IMAGE_DIGEST must be" in result.stdout


def _with_change(address: str, actions: list[str]) -> dict:
    plan = json.loads(json.dumps(PLAN))
    plan["resource_changes"].append(
        {"address": address, "change": {"actions": actions, "after": {}, "after_unknown": {}}}
    )
    return plan


@pytest.mark.parametrize("actions", [["delete"], ["delete", "create"], ["create", "delete"]])
def test_refuses_a_plan_that_deletes_the_running_service(stub, actions):
    plan = _with_change("module.service[0].aws_ecs_service.this", actions)
    result = stub("plan", plan=plan)
    assert result.returncode == 1
    assert "would DELETE the running ECS service" in result.stdout
    result = stub("apply", plan=plan, EXPECTED_DIGEST="0" * 64)
    assert result.returncode == 1
    assert not (stub.dir / "applied").exists()


@pytest.mark.parametrize(
    ("address", "actions"),
    [
        ("module.service[0].aws_ecs_service.this", ["create"]),  # first release
        ("module.service[0].aws_ecs_service.this", ["update"]),
        ("module.service[0].aws_ecs_task_definition.this", ["delete", "create"]),  # config change
    ],
)
def test_allows_creating_updating_and_new_task_definitions(stub, address, actions):
    assert stub("plan", plan=_with_change(address, actions)).returncode == 0


# --- Drift detection (Phase 7): reported, never fixed --------------------------------------------
def test_drift_reports_nothing_when_infrastructure_matches(stub):
    result = stub("drift", STUB_PLAN_RC="0")
    assert result.returncode == 0, result.stdout
    assert "No drift" in result.stdout
    assert not (stub.dir / "drift.md").exists()


def test_drift_is_reported_with_addresses_only_and_never_applied(stub):
    result = stub("drift", STUB_STATE="module.network.aws_vpc.this\n")
    assert result.returncode == 3, result.stdout
    report = (stub.dir / "drift.md").read_text()
    assert "`module.network.aws_vpc.this`" in report and "| create |" in report
    assert "10.40.0.0/20" not in report  # no values: the report becomes a public issue
    assert not (stub.dir / "applied").exists()


def test_drift_reports_not_deployed_after_cleanup(stub):
    """Empty state + 'create everything' is an environment that was cleaned up, not drift."""
    result = stub("drift", STUB_STATE="")
    assert result.returncode == 0, result.stdout
    assert "is not deployed" in result.stdout
    assert not (stub.dir / "drift.md").exists()


def test_drift_never_runs_in_destroy_mode(stub):
    assert stub("drift", TF_MODE="destroy").returncode == 2


# --- Cleanup (Phase 7): reviewed destroy, verified -------------------------------------------------
DESTROY = {"TF_MODE": "destroy", "CONFIRM_DESTROY": "destroy-dev"}
DELETE_ALL = {
    "format_version": "1.2",
    "resource_changes": [
        {"address": a, "change": {"actions": ["delete"], "after": None, "after_unknown": {}}}
        for a in ("module.service[0].aws_ecs_service.this", "module.load_balancer.aws_lb.this")
    ],
}


def destroy_digest(stub) -> str:
    result = stub("plan", plan=DELETE_ALL, TF_MODE="destroy")
    assert result.returncode == 0, result.stdout
    assert "-destroy" in (stub.dir / "plan_args").read_text()
    assert "run **cleanup**" in (stub.dir / "summary.md").read_text()
    return (stub.dir / "output").read_text().strip().split("digest=")[-1]


def test_destroy_plan_is_allowed_to_remove_the_service(stub):
    assert len(destroy_digest(stub)) == 64  # the "never delete the service" guard is for normal plans only


def test_cleanup_destroys_the_reviewed_plan_and_verifies_nothing_is_left(stub):
    digest = destroy_digest(stub)
    result = stub("apply", plan=DELETE_ALL, EXPECTED_DIGEST=digest, **DESTROY)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (stub.dir / "applied").exists()
    assert "Cleanup verified" in (stub.dir / "summary.md").read_text()


def test_cleanup_needs_the_typed_confirmation(stub):
    digest = destroy_digest(stub)
    result = stub("apply", plan=DELETE_ALL, EXPECTED_DIGEST=digest, TF_MODE="destroy", CONFIRM_DESTROY="yes")
    assert result.returncode == 2 and "CONFIRM_DESTROY=destroy-dev" in result.stdout
    assert not (stub.dir / "applied").exists()


@pytest.mark.parametrize(
    ("leftover", "message"),
    [
        ({"STUB_STATE": "module.network.aws_vpc.this\n"}, "still in state"),
        ({"STUB_ELB_RC": "0"}, "load balancer idp-dev still exists"),
    ],
)
def test_cleanup_fails_if_anything_is_left(stub, leftover, message):
    digest = destroy_digest(stub)
    result = stub("apply", plan=DELETE_ALL, EXPECTED_DIGEST=digest, **DESTROY, **leftover)
    assert result.returncode == 1 and message in result.stdout


def test_destroy_and_apply_digests_are_not_interchangeable(stub):
    """The same plan document hashes differently per mode: a reviewed destroy can never be applied
    as a normal apply, and a reviewed apply can never authorise a destroy."""
    apply_digest = plan_digest(stub)
    result = stub("apply", TF_MODE="destroy", CONFIRM_DESTROY="destroy-dev", EXPECTED_DIGEST=apply_digest)
    assert result.returncode == 1 and "Refusing to apply" in result.stdout
    assert not (stub.dir / "applied").exists()
