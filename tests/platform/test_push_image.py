"""scripts/push_image.sh: push under an immutable tag, publish the digest, never overwrite."""

import os
import shutil
import subprocess

import pytest
from validate_service import ROOT

SCRIPT = ROOT / "scripts" / "push_image.sh"
ACCOUNT = "111111111111"
SHA = "a" * 40
DIGEST = "sha256:" + "ef" * 32

AWS_STUB = """#!/usr/bin/env bash
echo "aws $*" >>"$STUB_DIR/calls.log"
case "$1 $2" in
  "sts get-caller-identity") echo 111111111111 ;;
  "ecr get-login-password") echo token ;;
  "ecr describe-images")
    if [ -f "$STUB_DIR/pushed" ] || [ -n "${STUB_ALREADY:-}" ]; then
      echo "{\\"imageDetails\\": [{\\"imageDigest\\": \\"$STUB_DIGEST\\"}]}"
    else
      echo "ImageNotFoundException" >&2; exit 254
    fi ;;
  *) exit 1 ;;
esac
"""

DOCKER_STUB = """#!/usr/bin/env bash
echo "docker $*" >>"$STUB_DIR/calls.log"
[ "$1" = push ] && touch "$STUB_DIR/pushed"
[ "$1" = login ] && cat >/dev/null
exit 0
"""


@pytest.fixture
def stub(tmp_path):
    if not shutil.which("jq"):
        pytest.skip("jq not installed")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in {"aws": AWS_STUB, "docker": DOCKER_STUB}.items():
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod(0o755)

    def run(**overrides: str) -> subprocess.CompletedProcess:
        env = {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(tmp_path),
            "RUNNER_TEMP": str(tmp_path),
            "GITHUB_STEP_SUMMARY": str(tmp_path / "summary.md"),
            "GITHUB_OUTPUT": str(tmp_path / "output"),
            "STUB_DIR": str(tmp_path),
            "STUB_DIGEST": DIGEST,
            "AWS_REGION": "us-east-2",
            "IMAGE": "sample-api:build",
            "ECR_REPOSITORY": "idp/sample-api",
            "GITHUB_SHA": SHA,
            **overrides,
        }
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, check=False)  # noqa: S603, S607

    run.dir = tmp_path
    return run


def test_pushes_under_the_commit_tag_and_publishes_the_digest(stub):
    result = stub()
    assert result.returncode == 0, result.stdout + result.stderr
    calls = (stub.dir / "calls.log").read_text()
    assert f"docker push --quiet {ACCOUNT}.dkr.ecr.us-east-2.amazonaws.com/idp/sample-api:git-{SHA}" in calls
    assert (stub.dir / "output").read_text() == f"digest={DIGEST}\n"
    summary = (stub.dir / "summary.md").read_text()
    assert DIGEST in summary and "Pushed now | yes" in summary
    assert "--password-stdin" in calls and "token" not in calls  # password never on a command line


def test_never_overwrites_a_published_commit(stub):
    result = stub(STUB_ALREADY="1")
    assert result.returncode == 0, result.stdout
    assert "docker push" not in (stub.dir / "calls.log").read_text()
    assert "already published" in (stub.dir / "summary.md").read_text()


def test_fails_without_a_valid_digest(stub):
    result = stub(STUB_DIGEST="None")
    assert result.returncode == 1
    assert "could not read the pushed image digest" in result.stdout


def test_refuses_missing_configuration(stub):
    result = stub(GITHUB_SHA="")
    assert result.returncode == 2
