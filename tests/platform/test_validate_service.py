"""Service manifest validation: schema + platform policy guardrails."""

import copy
import json
from pathlib import Path

import generate_catalog
import pytest
import yaml
from generate_catalog import build_catalog
from generate_catalog import render as render_catalog
from validate_service import ROOT, ManifestError, load_yaml, main, render, validate_all, validate_manifest

SAMPLE = ROOT / "apps" / "sample-api" / "service.yaml"
PROD_ON = {"spec.environments": {"prod": {"enabled": True, "desiredCount": 2}}}

VALID = {
    "apiVersion": "idp.platform/v1alpha1",
    "kind": "Service",
    "metadata": {"name": "orders-api", "owner": "team-payments", "description": "Order management service."},
    "spec": {
        "runtime": "python3.13",
        "container": {"port": 8080},
        "environments": {"dev": {"enabled": True}},
    },
}


def write(tmp_path: Path, manifest: dict, name: str = "service.yaml") -> Path:
    path = tmp_path / name
    path.write_text(yaml.safe_dump(manifest), encoding="utf-8")
    return path


def mutate(**changes) -> dict:
    """Return VALID with dotted-path changes applied, e.g. mutate(**{"spec.container.cpu": 512})."""
    m = copy.deepcopy(VALID)
    for dotted, value in changes.items():
        *parents, leaf = dotted.split(".")
        node = m
        for key in parents:
            node = node.setdefault(key, {})
        node[leaf] = value
    return m


def errors_for(tmp_path: Path, manifest: dict) -> list[str]:
    _, errs = validate_manifest(write(tmp_path, manifest))
    return errs


def test_sample_api_manifest_is_valid():
    _, errs = validate_manifest(SAMPLE)
    assert errs == []


def test_minimal_manifest_is_valid(tmp_path):
    assert errors_for(tmp_path, VALID) == []


@pytest.mark.parametrize(
    ("changes", "expected"),
    [
        # Developers cannot reach into IAM, networking, regions or arbitrary AWS resources.
        ({"spec.iamPolicy": {"Action": "*"}}, "Additional properties are not allowed ('iamPolicy'"),
        ({"spec.securityGroupIngress": ["0.0.0.0/0"]}, "Additional properties are not allowed"),
        ({"spec.region": "us-west-1"}, "Additional properties are not allowed ('region'"),
        ({"spec.container.privileged": True}, "Additional properties are not allowed ('privileged'"),
        ({"spec.resources": {"type": "AWS::RDS::DBInstance"}}, "Additional properties are not allowed"),
        # Structural rules.
        ({"apiVersion": "v2"}, "'idp.platform/v1alpha1' was expected"),
        ({"metadata.name": "Orders_API"}, "does not match"),
        ({"metadata.name": "a-name-that-is-far-too-long"}, "does not match"),
        ({"metadata.name": "double--dash"}, "does not match"),
        ({"metadata.owner": "payments"}, "does not match"),
        ({"spec.container.port": 80}, "less than the minimum of 1024"),
        ({"spec.container.cpu": 4096}, "is not one of"),
        ({"spec.container.cpu": 256, "spec.container.memory": 4096}, "is not one of [512, 1024, 2048]"),
        ({"spec.container.cpu": 512}, "'memory' is a required property"),
        ({"spec.deployment": {"strategy": "blue-green"}}, "'blue-green' is not one of ['rolling']"),
        ({"spec.environments": {"qa": {"enabled": True}}}, "'qa' is not one of"),
        ({"spec.healthCheck": {"path": "health"}}, "does not match"),
        ({"spec.secrets": [{"name": "DB_PASSWORD", "secretName": "arn:aws:secretsmanager:x"}]}, "does not match"),
    ],
)
def test_schema_rejects(tmp_path, changes, expected):
    errs = errors_for(tmp_path, mutate(**changes))
    assert any(expected in e for e in errs), errs


@pytest.mark.parametrize(
    ("changes", "expected"),
    [
        ({"metadata.owner": "team-unknown"}, "not an approved team"),
        ({"metadata.name": "admin"}, "is reserved"),
        ({"metadata.tags": {"owner": "someone-else"}}, "set by the platform"),
        ({"metadata.tags": {"managed-by": "me"}}, "set by the platform"),
        ({"spec.environmentVariables": {"AWS_REGION": "us-west-1"}}, "reserved by the platform"),
        ({"spec.environmentVariables": {"APP_VERSION": "9"}}, "reserved by the platform"),
        ({"spec.environmentVariables": {"DB_PASSWORD": "hunter2"}}, "looks like a secret"),
        ({"spec.environmentVariables": {"CONFIG": "AKIAABCDEFGHIJKLMNOP"}}, "looks like a credential"),
        (
            {"spec.environmentVariables": {"DB_URL": "x"}, "spec.secrets": [{"name": "DB_URL", "secretName": "db"}]},
            "also defined as a plain environment variable",
        ),
        ({"spec.environments": {"dev": {"enabled": True, "desiredCount": 5}}}, "exceeds the dev limit"),
        ({"spec.container.cpu": 1024, "spec.container.memory": 2048}, "exceeds the dev limit of 512"),
        ({"spec.environments": {"prod": {"enabled": True, "desiredCount": 1}}}, "prod requires at least 2"),
        (
            {**PROD_ON, "spec.deployment": {"circuitBreakerRollback": False}},
            "circuitBreakerRollback: required for prod",
        ),
        (
            {**PROD_ON, "spec.deployment": {"minimumHealthyPercent": 50}},
            "prod requires >= 100",
        ),
        ({"spec.healthCheck": {"intervalSeconds": 60, "unhealthyThreshold": 5}}, "<= 180s"),
        ({"spec.deployment": {"minimumHealthyPercent": 100, "maximumPercent": 100}}, "must be greater than"),
    ],
)
def test_policy_rejects(tmp_path, changes, expected):
    errs = errors_for(tmp_path, mutate(**changes))
    assert any(expected in e for e in errs), errs


def test_disabled_environment_limits_are_not_enforced(tmp_path):
    m = mutate(**{"spec.environments": {"dev": {"enabled": True}, "prod": {"enabled": False, "desiredCount": 1}}})
    assert errors_for(tmp_path, m) == []


def test_duplicate_yaml_keys_are_rejected(tmp_path):
    path = tmp_path / "service.yaml"
    text = yaml.safe_dump(VALID).replace("port: 8080", "port: 8080\n    port: 9090")
    path.write_text(text, encoding="utf-8")
    manifest, errs = validate_manifest(path)
    assert manifest is None
    assert "duplicate key 'port'" in errs[0]


def test_invalid_yaml_and_missing_file(tmp_path):
    bad = tmp_path / "service.yaml"
    bad.write_text("metadata: [unclosed", encoding="utf-8")
    assert "invalid YAML" in validate_manifest(bad)[1][0]
    assert validate_manifest(tmp_path / "missing.yaml")[1]


def test_yaml_tags_cannot_execute_code(tmp_path):
    path = tmp_path / "service.yaml"
    path.write_text("!!python/object/apply:os.system ['echo pwned']\n", encoding="utf-8")
    manifest, errs = validate_manifest(path)
    assert manifest is None
    assert errs


def test_name_must_match_directory(tmp_path):
    app_dir = tmp_path / "apps" / "other-name"
    app_dir.mkdir(parents=True)
    _, errs = validate_manifest(write(app_dir, VALID))
    assert any("must match its directory name" in e for e in errs)


def test_duplicate_service_names_across_manifests(tmp_path):
    a = write(tmp_path, VALID, "a.yaml")
    b = write(tmp_path, VALID, "b.yaml")
    results = validate_all([a, b])
    assert results[a] == []
    assert any("already used by" in e for e in results[b])


def test_render_applies_defaults_and_scopes_secrets(tmp_path):
    m = mutate(**{"spec.secrets": [{"name": "DB_PASSWORD", "secretName": "orders-db"}]})
    out = render(m, "dev")
    assert out["cpu"] == 256
    assert out["memory"] == 512
    assert out["desired_count"] == 1
    assert out["health_check"]["path"] == "/health"
    assert out["deployment"]["circuitBreakerRollback"] is True
    # Secret references are always namespaced to this environment + service.
    assert out["secrets"] == {"DB_PASSWORD": "idp/dev/orders-api/orders-db"}


def test_render_refuses_disabled_environment():
    with pytest.raises(ManifestError, match="not enabled in 'prod'"):
        render(load_yaml(SAMPLE), "prod")


def test_cli_exit_codes(tmp_path, capsys):
    assert main([str(SAMPLE)]) == 0
    assert main([str(write(tmp_path, mutate(**{"metadata.owner": "team-nope"})))]) == 1
    assert "FAIL" in capsys.readouterr().out


def test_cli_render(capsys):
    assert main(["--render", "dev", str(SAMPLE)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["service_name"] == "sample-api"
    assert out["environment"] == "dev"


def test_catalog_is_generated_from_manifests():
    catalog = build_catalog([SAMPLE])
    (entry,) = catalog["services"]
    assert entry == {
        "name": "sample-api",
        "owner": "team-platform",
        "description": "Reference FastAPI workload used to demonstrate the platform's delivery pipeline.",
        "tier": "experimental",
        "path": "apps/sample-api",
        "runtime": "python3.13",
        "port": 8080,
        "size": "256 CPU / 512 MiB",
        "health_check": "/health",
        "environments": ["dev"],
    }


def test_committed_catalog_is_up_to_date():
    committed = (ROOT / "platform" / "catalog" / "services.yaml").read_text(encoding="utf-8")
    assert committed == render_catalog(build_catalog(sorted((ROOT / "apps").glob("*/service.yaml"))))


def test_catalog_refuses_invalid_manifests(tmp_path):
    bad = write(tmp_path, mutate(**{"metadata.owner": "team-nope"}))
    with pytest.raises(ValueError, match="invalid manifests"):
        build_catalog([bad], root=tmp_path)


def test_catalog_cli_write_and_check(tmp_path, monkeypatch, capsys):
    target = tmp_path / "services.yaml"
    monkeypatch.setattr(generate_catalog, "CATALOG_PATH", target)
    assert generate_catalog.main(["--check"]) == 1  # missing => stale
    assert generate_catalog.main([]) == 0
    assert generate_catalog.main(["--check"]) == 0
    target.write_text("tampered", encoding="utf-8")
    assert generate_catalog.main(["--check"]) == 1
    assert "is stale" in capsys.readouterr().err


def test_catalog_cli_reports_invalid_manifests(monkeypatch, capsys, tmp_path):
    bad = write(tmp_path, mutate(**{"metadata.owner": "team-nope"}))
    monkeypatch.setattr(generate_catalog, "discover", lambda _apps: [bad])
    assert generate_catalog.main(["--check"]) == 1
    assert "invalid manifests" in capsys.readouterr().err
