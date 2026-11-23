"""Self-service (Phase 6): a service generated from the template must pass CI unchanged.

Exit criterion of Phase 6 (docs/deployment-plan.md): "A new service created from the template
passes CI unchanged". These tests generate a service into a temporary apps/ directory and run the
same checks CI runs on it: manifest schema + policy, its own test suite with the 90% coverage gate,
Ruff, and the catalog.
"""

import filecmp
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import generate_catalog
import new_service
import pytest
import test_services
from validate_service import ROOT, validate_all

SAMPLE = ROOT / "apps" / "sample-api"
SAMPLE_DESCRIPTION = "Reference FastAPI workload used to demonstrate the platform's delivery pipeline."
ORDERS = ("orders-api", "team-payments", "Order intake for the shop.")
RUFF = shutil.which("ruff")


def create(apps_dir, name=ORDERS[0], owner=ORDERS[1], description=ORDERS[2], catalog=False):
    args = [name, "--owner", owner, "--description", description, "--apps-dir", str(apps_dir)]
    return new_service.main(args if catalog else [*args, "--no-catalog"])


def _files(base):
    found = (p.relative_to(base) for p in base.rglob("*") if p.is_file())
    return sorted(p for p in found if not set(p.parts) & new_service.SKIP)


def test_template_is_exactly_the_reference_service(tmp_path):
    """Rendering the template with sample-api's values reproduces apps/sample-api byte for byte.

    The template therefore cannot drift from the service that is really built, scanned and deployed.
    """
    out = tmp_path / "sample-api"
    new_service.render_tree(out, "sample-api", "team-platform", SAMPLE_DESCRIPTION)
    assert _files(out) == _files(SAMPLE)
    _, mismatch, errors = filecmp.cmpfiles(out, SAMPLE, [str(p) for p in _files(SAMPLE)], shallow=False)
    assert mismatch == [] and errors == [], f"template and apps/sample-api differ: {mismatch or errors}"


@pytest.fixture
def generated(tmp_path):
    apps = tmp_path / "apps"
    apps.mkdir()
    assert create(apps) == 0
    return apps / "orders-api"


def test_generated_manifest_passes_schema_and_policy(generated):
    results = validate_all([generated / "service.yaml"])
    assert results == {generated / "service.yaml": []}


def test_generated_service_tests_pass_with_coverage_gate(generated):
    """The new service's own suite, exactly as `make test-apps` runs it in CI."""
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "--cov"], cwd=generated, capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stdout[-3000:]
    assert "Required test coverage of 90.0% reached" in result.stdout


@pytest.mark.skipif(RUFF is None, reason="ruff not installed")
def test_generated_service_passes_ruff():
    """Ruff exactly as CI runs it. Generated INSIDE the repository: per-file rules such as "asserts are
    fine in tests/" are matched relative to the project root, so a temp dir elsewhere would not apply them."""
    scratch = Path(tempfile.mkdtemp(prefix=".tmp-new-service-", dir=ROOT))
    try:
        target = scratch / "apps" / "orders-api"
        new_service.render_tree(target, *ORDERS)
        for args in (["check"], ["format", "--check"]):
            result = subprocess.run(  # noqa: S603 - fixed argv
                [RUFF, *args, str(target)], cwd=ROOT, capture_output=True, text=True, check=False
            )
            assert result.returncode == 0, result.stdout + result.stderr
    finally:
        shutil.rmtree(scratch)


def test_generated_service_is_renamed_everywhere(generated):
    text = "\n".join(p.read_text(encoding="utf-8") for p in generated.rglob("*") if p.is_file())
    assert "sample-api" not in text and "sample_api" not in text
    assert "{{" not in text.replace("{{method", "")  # the only literal "{{" is an f-string escape in metrics.py
    assert 'logging.getLogger("orders_api")' in (generated / "app" / "main.py").read_text(encoding="utf-8")
    assert 'title="orders-api"' in (generated / "Dockerfile").read_text(encoding="utf-8")


def test_generated_service_appears_in_the_catalog(generated):
    catalog = generate_catalog.build_catalog(generate_catalog.discover(generated.parent), root=generated.parent.parent)
    assert [s["name"] for s in catalog["services"]] == ["orders-api"]
    assert catalog["services"][0]["owner"] == "team-payments"
    page = generate_catalog.render_page(catalog)
    assert "| [`orders-api`](../apps/orders-api) | team-payments |" in page


def test_test_runner_discovers_every_service(generated):
    assert test_services.services(generated.parent) == [generated]


@pytest.mark.parametrize(
    ("request_args", "message"),
    [
        ({"name": "Orders"}, "lowercase"),
        ({"name": "a"}, "lowercase"),
        ({"name": "orders--api"}, "lowercase"),
        ({"owner": "team-unknown"}, "approved"),
        ({"name": "admin"}, "reserved"),
        ({"description": "short"}, "description"),
        ({"description": 'Has a "quote" inside it.'}, "description must be one line"),
    ],
)
def test_rejects_invalid_requests(tmp_path, capsys, request_args, message):
    assert create(tmp_path, **request_args) == 1
    assert message in capsys.readouterr().err
    assert not any(tmp_path.iterdir())  # nothing written


def test_refuses_to_overwrite_an_existing_service(tmp_path, capsys):
    (tmp_path / "orders-api").mkdir()
    assert create(tmp_path) == 1
    assert "already exists" in capsys.readouterr().err


def test_updates_the_catalog_files(tmp_path, monkeypatch):
    written = []
    monkeypatch.setattr(new_service, "write_catalog", lambda: written.append(True) or [generate_catalog.CATALOG_PATH])
    assert create(tmp_path, catalog=True) == 0
    assert written == [True]


def test_catalog_page_is_generated_and_checked(tmp_path, monkeypatch, capsys):
    page = tmp_path / "service-catalog.md"
    monkeypatch.setattr(generate_catalog, "PAGE_PATH", page)
    monkeypatch.setattr(generate_catalog, "CATALOG_PATH", tmp_path / "services.yaml")
    assert generate_catalog.main([]) == 0
    assert "[`sample-api`](../apps/sample-api)" in page.read_text(encoding="utf-8")
    assert generate_catalog.main(["--check"]) == 0
    page.write_text("stale", encoding="utf-8")
    assert generate_catalog.main(["--check"]) == 1
    assert "service-catalog.md is stale" in capsys.readouterr().err
