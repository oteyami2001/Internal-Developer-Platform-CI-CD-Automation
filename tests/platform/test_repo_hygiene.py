"""Repository-level guardrails: workflow security rules, Terraform exceptions, committed files.

These turn conventions into failing tests, so a future change cannot quietly weaken them.
"""

import json
import re
import subprocess
import tomllib
from pathlib import Path

import pytest
import yaml
from validate_service import ROOT

WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
SHA_PIN = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$")
TFLINT_SKELETON_IGNORE = "# tflint-ignore-file: terraform_unused_declarations"


def load_workflow(path: Path) -> dict:
    # PyYAML (YAML 1.1) parses the key `on` as boolean True; normalise it.
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if True in data:
        data["on"] = data.pop(True)
    return data


def iter_steps(workflow: dict):
    for job_name, job in workflow["jobs"].items():
        for step in job.get("steps", []):
            yield job_name, step


def test_workflows_exist():
    assert WORKFLOWS, "no workflows found"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_actions_are_pinned_to_full_commit_shas(path):
    for job, step in iter_steps(load_workflow(path)):
        uses = step.get("uses")
        if uses and not uses.startswith("./"):
            assert SHA_PIN.match(uses), f"{path.name}/{job}: '{uses}' must be pinned to a 40-char commit SHA"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_permissions_are_least_privilege(path):
    wf = load_workflow(path)
    assert wf.get("permissions") == {}, f"{path.name}: workflow-level permissions must be {{}} (grant per job)"
    for name, job in wf["jobs"].items():
        assert "permissions" in job, f"{path.name}/{name}: job must declare its permissions explicitly"
        perms = job["permissions"]
        assert perms != "write-all" and "write-all" not in str(perms), f"{path.name}/{name}: write-all"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_no_pull_request_target(path):
    assert "pull_request_target" not in load_workflow(path)["on"], (
        f"{path.name}: pull_request_target runs untrusted PR code with secrets"
    )


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_checkout_does_not_persist_credentials(path):
    for job, step in iter_steps(load_workflow(path)):
        if str(step.get("uses", "")).startswith("actions/checkout@"):
            assert step.get("with", {}).get("persist-credentials") is False, f"{path.name}/{job}"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_no_expressions_in_run_scripts(path):
    # ${{ }} inside `run:` is expanded before the shell parses it: a classic injection vector.
    # Pass values through `env:` instead.
    for job, step in iter_steps(load_workflow(path)):
        run = step.get("run", "")
        assert "${{" not in run, f"{path.name}/{job}/{step.get('name')}: move the expression into env:"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_bash_with_pipefail_is_the_default_shell(path):
    assert load_workflow(path).get("defaults", {}).get("run", {}).get("shell") == "bash", path.name


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_jobs_have_timeouts(path):
    for name, job in load_workflow(path)["jobs"].items():
        assert "timeout-minutes" in job, f"{path.name}/{name}: set timeout-minutes (stale runs/approvals)"


def test_ci_never_gets_aws_credentials():
    """ADR 0003: the PR-facing workflow has no OIDC token and no AWS credential action."""
    ci = load_workflow(ROOT / ".github" / "workflows" / "ci.yml")
    text = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
    for name, job in ci["jobs"].items():
        assert "id-token" not in (job.get("permissions") or {}), f"ci.yml/{name} must not request id-token"
        assert "environment" not in job, f"ci.yml/{name} must not use a deployment environment"
    assert "configure-aws-credentials" not in text
    assert "secrets." not in text, "ci.yml must not reference repository secrets"


def test_ci_ok_aggregates_every_job():
    ci = load_workflow(ROOT / ".github" / "workflows" / "ci.yml")
    jobs = set(ci["jobs"]) - {"ci-ok"}
    assert set(ci["jobs"]["ci-ok"]["needs"]) == jobs, "ci-ok must depend on every other CI job"
    assert ci["jobs"]["ci-ok"]["if"] == "always()"


def _terraform_dirs() -> list[Path]:
    tf = ROOT / "terraform"
    return [tf / "bootstrap", tf / "stack", *sorted(p for p in (tf / "modules").iterdir() if p.is_dir())]


@pytest.mark.parametrize("directory", _terraform_dirs(), ids=lambda p: p.relative_to(ROOT).as_posix())
def test_unused_declaration_ignore_only_while_skeleton(directory):
    """The file-level TFLint ignore is allowed only while a configuration has no resources/modules."""
    sources = {p: p.read_text(encoding="utf-8") for p in directory.glob("*.tf")}
    has_ignore = any(TFLINT_SKELETON_IGNORE in s for s in sources.values())
    has_resources = any(re.search(r'^\s*(resource|module)\s+"', s, re.M) for s in sources.values())
    if has_resources:
        assert not has_ignore, (
            f"{directory.relative_to(ROOT)} now has resources: remove the skeleton "
            "`tflint-ignore-file: terraform_unused_declarations` line"
        )


def test_no_state_plans_or_secrets_are_tracked():
    files = subprocess.run(
        ["git", "ls-files"],  # noqa: S607 - git resolved from PATH in CI and dev shells
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    forbidden = re.compile(
        r"(\.tfstate(\.|$)|\.tfplan$|(^|/)tfplan$|(^|/)backend\.hcl$|\.auto\.tfvars|(^|/)\.env$|\.pem$)"
    )
    offenders = [f for f in files if forbidden.search(f)]
    assert offenders == [], offenders


def test_committed_tfvars_hold_no_identifying_values():
    for path in (ROOT / "terraform" / "envs").glob("*/terraform.tfvars"):
        text = path.read_text(encoding="utf-8")
        for name in ("aws_account_id", "alert_email", "allowed_ingress_cidrs"):
            assert not re.search(rf"^\s*{name}\s*=", text, re.M), f"{path}: {name} must come from TF_VAR_*"
        assert not re.search(r"\b\d{12}\b", text), f"{path}: looks like an AWS account ID"


# --- Python version standard (ADR 0006): everything says 3.13, nothing drifts silently ---------
PYTHON_STANDARD = "3.13"


def test_dockerfile_stages_use_digest_pinned_python_standard():
    froms = re.findall(r"^FROM\s+(\S+)", (ROOT / "apps" / "sample-api" / "Dockerfile").read_text(), re.M)
    assert froms, "no FROM lines"
    for image in froms:
        assert re.fullmatch(rf"python:{re.escape(PYTHON_STANDARD)}-slim@sha256:[0-9a-f]{{64}}", image), image


def test_ci_python_version_is_the_standard():
    ci = load_workflow(ROOT / ".github" / "workflows" / "ci.yml")
    assert str(ci["env"]["PYTHON_VERSION"]) == PYTHON_STANDARD


def test_pyproject_targets_the_standard():
    data = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    assert data["project"]["requires-python"] == ">=3.13,<3.14"
    assert data["tool"]["ruff"]["target-version"] == "py313"


def test_dev_environment_uses_the_standard():
    assert (ROOT / ".python-version").read_text(encoding="utf-8").strip() == PYTHON_STANDARD
    text = (ROOT / ".devcontainer" / "devcontainer.json").read_text(encoding="utf-8")
    devcontainer = json.loads("\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//")))
    assert devcontainer["image"].endswith(f":1-{PYTHON_STANDARD}-bookworm"), devcontainer["image"]


def test_service_runtime_is_the_standard():
    schema = json.loads((ROOT / "platform" / "schemas" / "service.schema.json").read_text(encoding="utf-8"))
    assert schema["properties"]["spec"]["properties"]["runtime"]["enum"] == [f"python{PYTHON_STANDARD}"]
    for manifest in (ROOT / "apps").glob("*/service.yaml"):
        assert yaml.safe_load(manifest.read_text(encoding="utf-8"))["spec"]["runtime"] == f"python{PYTHON_STANDARD}"


def test_dependabot_never_proposes_python_minor_or_major_jumps():
    config = yaml.safe_load((ROOT / ".github" / "dependabot.yml").read_text(encoding="utf-8"))
    docker = [u for u in config["updates"] if u["package-ecosystem"] == "docker"]
    assert docker, "docker ecosystem missing"
    for update in docker:
        rules = [r for r in update.get("ignore", []) if r.get("dependency-name") == "python"]
        assert rules, "python base image must have an ignore rule"
        types = {t for r in rules for t in r.get("update-types", [])}
        assert types == {"version-update:semver-major", "version-update:semver-minor"}, types
