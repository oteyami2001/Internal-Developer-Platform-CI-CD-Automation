"""Repository-level guardrails: workflow security rules, Terraform exceptions, committed files.

These turn conventions into failing tests, so a future change cannot quietly weaken them.
"""

import ipaddress
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


# --- Workflows that can obtain AWS credentials -------------------------------------------------
def _aws_jobs():
    for path in WORKFLOWS:
        wf = load_workflow(path)
        for name, job in wf["jobs"].items():
            if (job.get("permissions") or {}).get("id-token") == "write":
                yield path, wf, name, job


def test_aws_workflows_exist():
    assert {p.name for p, *_ in _aws_jobs()} == {
        "terraform-plan.yml",
        "terraform-apply.yml",
        "image-build.yml",
        "app-deploy.yml",
    }


@pytest.mark.parametrize(("path", "wf", "name", "job"), list(_aws_jobs()), ids=lambda v: getattr(v, "name", None))
def test_aws_jobs_are_gated(path, wf, name, job):
    where = f"{path.name}/{name}"
    assert job.get("if") == "github.ref == 'refs/heads/main'", f"{where}: must be limited to main"
    triggers = set(wf["on"]) if isinstance(wf["on"], dict) else {wf["on"]}
    if path.name == "image-build.yml":
        # The one exception: publishing (not deploying) an image after a reviewed merge to main. Its
        # role trusts ref:refs/heads/main only and can push to ECR, nothing else.
        assert "environment" not in job, where
        assert triggers <= {"push", "workflow_dispatch"}, where
        assert wf["on"]["push"]["branches"] == ["main"], f"{where}: pushes to main only"
    else:
        # A protected environment: the OIDC trust names it, and GitHub enforces reviewers/branches on it.
        assert job.get("environment") in {"dev-plan", "dev", "dev-deploy"}, (
            f"{where}: must run in a protected environment"
        )
        assert triggers <= {"workflow_dispatch", "schedule"}, f"{where}: AWS workflows are manual (or scheduled) only"
    creds = [s for s in job["steps"] if str(s.get("uses", "")).startswith("aws-actions/configure-aws-credentials@")]
    assert len(creds) == 1, f"{where}: exactly one credentials step"
    assert creds[0]["with"].get("mask-aws-account-id") is True, f"{where}: mask the account ID in public logs"
    assert "role-to-assume" in creds[0]["with"] and "aws-access-key-id" not in creds[0]["with"], where


def test_apply_requires_the_reviewed_digest():
    wf = load_workflow(ROOT / ".github" / "workflows" / "terraform-apply.yml")
    assert wf["on"]["workflow_dispatch"]["inputs"]["plan_digest"]["required"] is True
    job = wf["jobs"]["apply"]
    assert job["environment"] == "dev"
    assert job["env"]["EXPECTED_DIGEST"] == "${{ inputs.plan_digest }}"
    assert any("tf_ci.sh apply" in s.get("run", "") for s in job["steps"])
    plan = load_workflow(ROOT / ".github" / "workflows" / "terraform-plan.yml")
    assert plan["jobs"]["plan"]["environment"] == "dev-plan"
    assert "upload-artifact" not in (ROOT / ".github" / "workflows" / "terraform-plan.yml").read_text(), (
        "plan files contain plaintext variables: never upload them from a public repository"
    )


def test_image_is_pushed_only_after_smoke_test_and_trivy_gate():
    job = load_workflow(ROOT / ".github" / "workflows" / "image-build.yml")["jobs"]["build"]
    names = [s.get("name") or s.get("uses", "") for s in job["steps"]]
    creds = next(i for i, s in enumerate(job["steps"]) if "configure-aws-credentials" in s.get("uses", ""))
    smoke = next(i for i, n in enumerate(names) if n.startswith("Smoke test"))
    gate = next(i for i, s in enumerate(job["steps"]) if s.get("with", {}).get("exit-code") == "1")
    assert smoke < creds and gate < creds, "no AWS credentials before the image passed its gates"
    assert job["steps"][gate]["with"]["severity"] == "HIGH,CRITICAL"
    assert job["steps"][creds]["with"]["role-to-assume"] == "${{ secrets.AWS_IMAGE_PUSH_ROLE_ARN }}"
    assert any(s.get("run") == "scripts/push_image.sh" for s in job["steps"][creds:])


def test_deploy_requires_a_digest_and_the_deploy_environment():
    wf = load_workflow(ROOT / ".github" / "workflows" / "app-deploy.yml")
    assert wf["on"]["workflow_dispatch"]["inputs"]["image_digest"]["required"] is True
    job = wf["jobs"]["deploy"]
    assert job["environment"] == "dev-deploy"
    assert job["env"]["IMAGE_DIGEST"] == "${{ inputs.image_digest }}"
    assert any(s.get("run") == "scripts/app_deploy.sh dev" for s in job["steps"])


def test_terraform_workflows_pass_the_initial_image_digest_only():
    for name in ("terraform-plan.yml", "terraform-apply.yml"):
        env = next(iter(load_workflow(ROOT / ".github" / "workflows" / name)["jobs"].values()))["env"]
        assert env["SERVICE_IMAGE_DIGEST"] == "${{ vars.SERVICE_IMAGE_DIGEST }}", name
        assert "SERVICE_IMAGE" not in env, name


# GitHub prints `vars.*` in clear text in public logs (every step echoes the job env). Found in
# Phase 5: the operator's IP and the account ID (role ARNs, bucket name) were visible in run logs.
PUBLIC_VARIABLES = {"AWS_REGION", "SERVICE_IMAGE_DIGEST"}


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_only_non_identifying_values_are_variables(path):
    used = set(re.findall(r"\$\{\{\s*vars\.([A-Za-z0-9_]+)", path.read_text(encoding="utf-8")))
    assert used <= PUBLIC_VARIABLES, f"{path.name}: {sorted(used - PUBLIC_VARIABLES)} must be secrets (masked in logs)"


def test_configuration_script_stores_identifying_values_as_secrets():
    script = (ROOT / "scripts" / "configure_github_environments.sh").read_text(encoding="utf-8")
    assert set(re.findall(r"^gh variable set (\w+)", script, re.M)) <= PUBLIC_VARIABLES
    for name in ("AWS_ROLE_ARN", "TF_STATE_BUCKET", "AWS_IMAGE_PUSH_ROLE_ARN", "ALLOWED_INGRESS_CIDR", "ALERT_EMAIL"):
        assert re.search(rf"^\s*gh secret set {name}\b", script, re.M), name


CIDR = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})/\d{1,2}(?![\d.])")


def test_no_public_ip_addresses_are_committed():
    """The operator's home /32 is personal data: it lives only in a GitHub environment variable."""
    allowed_networks = [
        ipaddress.ip_network(n)
        for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "0.0.0.0/32", "255.255.255.255/32")
    ]
    files = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],  # noqa: S607
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    offenders = []
    for name in files:
        path = ROOT / name
        if not path.is_file() or path.suffix in {".png", ".jpg", ".zip"} or name.endswith(".lock.hcl"):
            continue
        # CIDR notation only (that is how ingress addresses are written); bare dotted numbers are
        # mostly 4-part package versions.
        for match in CIDR.finditer(path.read_text(errors="ignore")):
            try:
                ip = ipaddress.ip_address(match.group(1))
            except ValueError:
                continue
            if ip.is_global and not any(ip in net for net in allowed_networks):
                offenders.append(f"{name}: {ip}")
    assert offenders == [], offenders
