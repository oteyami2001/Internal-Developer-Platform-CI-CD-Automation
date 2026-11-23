"""scripts/app_deploy.sh: release a digest-pinned image to the ECS service, verified.

`aws` is a stub on PATH that plays ECR/ECS/ELB and records what the script asked for; the real
manifest renderer and jq run.
"""

import json
import os
import shutil
import subprocess
import sys

import pytest
from validate_service import ROOT

SCRIPT = ROOT / "scripts" / "app_deploy.sh"
ACCOUNT = "111111111111"
DIGEST = "sha256:" + "cd" * 32
OLD_TD = f"arn:aws:ecs:us-east-2:{ACCOUNT}:task-definition/idp-dev-sample-api:1"
NEW_TD = f"arn:aws:ecs:us-east-2:{ACCOUNT}:task-definition/idp-dev-sample-api:2"

CURRENT_TD = {
    "taskDefinition": {
        "taskDefinitionArn": OLD_TD,
        "family": "idp-dev-sample-api",
        "revision": 1,
        "status": "ACTIVE",
        "cpu": "256",
        "memory": "512",
        "executionRoleArn": f"arn:aws:iam::{ACCOUNT}:role/idp-dev-sample-api-exec",
        "taskRoleArn": f"arn:aws:iam::{ACCOUNT}:role/idp-dev-sample-api-task",
        "networkMode": "awsvpc",
        "requiresCompatibilities": ["FARGATE"],
        "compatibilities": ["EC2", "FARGATE"],
        "requiresAttributes": [{"name": "com.amazonaws.ecs.capability.logging-driver.awslogs"}],
        "registeredAt": "2026-11-23T07:00:00Z",
        "registeredBy": "arn:aws:sts::111111111111:assumed-role/idp-dev-github-apply/x",
        "containerDefinitions": [
            {
                "name": "sample-api",
                "image": f"{ACCOUNT}.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api@sha256:{'0' * 64}",
                "user": "10001:10001",
                "readonlyRootFilesystem": True,
                "linuxParameters": {"capabilities": {"drop": ["ALL"]}},
            }
        ],
    }
}

AWS_STUB = r"""#!/usr/bin/env python3
import json, os, sys
d = os.environ["STUB_DIR"]
args = sys.argv[1:]
cmd = " ".join(args[:2])
def log():
    with open(os.path.join(d, "calls.log"), "a") as f:
        f.write(" ".join(args) + "\n")
def out(obj):
    print(json.dumps(obj))
def count(name):
    p = os.path.join(d, name)
    n = int(open(p).read()) + 1 if os.path.exists(p) else 1
    open(p, "w").write(str(n))
    return n
log()
mode = os.environ.get("STUB_MODE", "ok")
if cmd == "sts get-caller-identity":
    print(os.environ["STUB_CALLER_ACCOUNT"])
elif cmd == "ecr describe-images":
    if mode == "no-image":
        sys.stderr.write("ImageNotFoundException\n"); sys.exit(254)
    out({"imageDetails": [{"imageDigest": os.environ["IMAGE_DIGEST"], "imageTags": ["git-abc"]}]})
elif cmd == "ecr describe-image-scan-findings":
    out({"imageScanStatus": {"status": "COMPLETE"}, "imageScanFindings": {"findingSeverityCounts": {"MEDIUM": 2}}})
elif cmd == "ecs describe-services":
    n = count("describe_services")
    if mode == "no-service":
        out({"services": [], "failures": [{"reason": "MISSING"}]}); sys.exit(0)
    new, old = os.environ["STUB_NEW_TD"], os.environ["STUB_OLD_TD"]
    if n == 1:
        deployments = [{"status": "PRIMARY", "taskDefinition": old, "rolloutState": "COMPLETED"}]
    elif mode == "rollback":
        deployments = [{"status": "PRIMARY", "taskDefinition": old, "rolloutState": "IN_PROGRESS"},
                       {"status": "ACTIVE", "taskDefinition": new, "rolloutState": "FAILED",
                        "rolloutStateReason": "circuit breaker: tasks failed to start"}]
    elif mode == "stuck" or n == 2:
        deployments = [{"status": "PRIMARY", "taskDefinition": new, "rolloutState": "IN_PROGRESS"},
                       {"status": "ACTIVE", "taskDefinition": old, "rolloutState": "COMPLETED"}]
    elif mode == "wrong-primary":
        deployments = [{"status": "PRIMARY", "taskDefinition": old, "rolloutState": "COMPLETED"},
                       {"status": "ACTIVE", "taskDefinition": new, "rolloutState": "COMPLETED"}]
    else:
        deployments = [{"status": "PRIMARY", "taskDefinition": new, "rolloutState": "COMPLETED"}]
    out({"services": [{"status": "ACTIVE", "taskDefinition": deployments[0]["taskDefinition"],
                       "deployments": deployments,
                       "loadBalancers": [{"targetGroupArn": "arn:aws:elasticloadbalancing:tg/idp-dev-tg"}]}]})
elif cmd == "ecs describe-task-definition":
    print(open(os.environ["STUB_CURRENT_TD"]).read())
elif cmd == "ecs register-task-definition":
    src = args[args.index("--cli-input-json") + 1].removeprefix("file://")
    open(os.path.join(d, "registered.json"), "w").write(open(src).read())
    out({"taskDefinition": {"taskDefinitionArn": os.environ["STUB_NEW_TD"]}})
elif cmd == "ecs update-service":
    open(os.path.join(d, "updated"), "w").write(args[args.index("--task-definition") + 1])
    out({"service": {}})
elif cmd == "elbv2 describe-target-health":
    healthy = 0 if mode == "unhealthy" else 1
    out({"TargetHealthDescriptions": [{"TargetHealth": {"State": "healthy"}}] * healthy
         + [{"TargetHealth": {"State": "draining"}}]})
else:
    sys.stderr.write("unexpected call: " + " ".join(args) + "\n"); sys.exit(1)
"""


@pytest.fixture
def stub(tmp_path):
    if not shutil.which("jq"):
        pytest.skip("jq not installed")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    aws = bin_dir / "aws"
    aws.write_text(AWS_STUB.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
    aws.chmod(0o755)
    current = tmp_path / "current-td-fixture.json"
    current.write_text(json.dumps(CURRENT_TD))

    def run(mode: str = "ok", **overrides: str) -> subprocess.CompletedProcess:
        env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(tmp_path),
            "RUNNER_TEMP": str(tmp_path),
            "GITHUB_STEP_SUMMARY": str(tmp_path / "summary.md"),
            "STUB_DIR": str(tmp_path),
            "STUB_MODE": mode,
            "STUB_CALLER_ACCOUNT": ACCOUNT,
            "STUB_CURRENT_TD": str(current),
            "STUB_OLD_TD": OLD_TD,
            "STUB_NEW_TD": NEW_TD,
            "AWS_ROLE_ARN": f"arn:aws:iam::{ACCOUNT}:role/idp-dev-github-deploy",
            "AWS_REGION": "us-east-2",
            "IMAGE_DIGEST": DIGEST,
            "DEPLOY_POLL_SECONDS": "0",
            "DEPLOY_TIMEOUT_SECONDS": "3",
            **overrides,
        }
        return subprocess.run(["bash", str(SCRIPT), "dev"], env=env, capture_output=True, text=True, check=False)  # noqa: S603, S607

    run.dir = tmp_path
    return run


def test_deploys_the_digest_and_changes_only_the_image(stub):
    result = stub()
    assert result.returncode == 0, result.stdout + result.stderr
    registered = json.loads((stub.dir / "registered.json").read_text())
    expected = json.loads(json.dumps(CURRENT_TD["taskDefinition"]))
    for key in (
        "taskDefinitionArn",
        "revision",
        "status",
        "requiresAttributes",
        "compatibilities",
        "registeredAt",
        "registeredBy",
    ):
        expected.pop(key)
    expected["containerDefinitions"][0]["image"] = f"{ACCOUNT}.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api@{DIGEST}"
    tags = {t["key"]: t["value"] for t in registered.pop("tags")}
    assert registered == expected  # hardened settings (user, read-only FS, capabilities, roles) unchanged
    assert tags == {
        "Project": "idp",
        "Environment": "dev",
        "ManagedBy": "app-deploy",
        "ImageDigest": DIGEST,
        "Repository": "oteyami2001/Internal-Developer-Platform-CI-CD-Automation",
    }
    assert (stub.dir / "updated").read_text() == NEW_TD
    summary = (stub.dir / "summary.md").read_text()
    assert "**DEPLOYED**" in summary and "`idp-dev-sample-api:1` → `idp-dev-sample-api:2`" in summary
    assert "Healthy targets | 1" in summary and "COMPLETE MEDIUM=2" in summary
    assert ACCOUNT not in summary  # short names only, no ARNs


@pytest.mark.parametrize("bad", ["latest", "git-abc", "sha256:" + "CD" * 32, "sha256:abc", DIGEST + "0", ""])
def test_only_a_digest_is_accepted(stub, bad):
    result = stub(IMAGE_DIGEST=bad)
    assert result.returncode == 2
    assert not (stub.dir / "calls.log").exists()  # refused before any AWS call


def test_refuses_credentials_for_another_account(stub):
    result = stub(STUB_CALLER_ACCOUNT="222222222222")
    assert result.returncode == 1 and "another account" in result.stdout
    assert not (stub.dir / "updated").exists()


def test_refuses_an_image_that_is_not_in_the_repository(stub):
    result = stub("no-image")
    assert result.returncode == 1 and "is not in idp/sample-api" in result.stdout
    assert not (stub.dir / "registered.json").exists()


def test_does_not_create_a_missing_service(stub):
    result = stub("no-service")
    assert result.returncode == 1 and "first release is created by Terraform" in result.stdout
    assert not (stub.dir / "registered.json").exists()


def test_circuit_breaker_rollback_fails_the_job(stub):
    """services-stable would pass here (the old revision is stable again); the job must not."""
    result = stub("rollback")
    assert result.returncode == 1
    assert "circuit breaker: tasks failed to start" in result.stdout
    assert "**FAILED**" in (stub.dir / "summary.md").read_text()


def test_timeout_fails_the_job(stub):
    result = stub("stuck", DEPLOY_TIMEOUT_SECONDS="1", DEPLOY_POLL_SECONDS="1")
    assert result.returncode == 1 and "did not complete (IN_PROGRESS: timed out after 1s" in result.stdout


def test_completed_but_not_primary_fails(stub):
    result = stub("wrong-primary")
    assert result.returncode == 1 and "primary deployment runs" in result.stdout


def test_no_healthy_targets_fails(stub):
    result = stub("unhealthy")
    assert result.returncode == 1 and "no healthy targets" in result.stdout


def test_cli_rejects_unknown_environment():
    result = subprocess.run(["bash", str(SCRIPT), "qa"], capture_output=True, text=True, check=False)  # noqa: S603, S607
    assert result.returncode == 2
