import json
import logging

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

BUILD_ENV = {
    "SERVICE_NAME": "{{service_name}}",
    "APP_ENV": "dev",
    "APP_VERSION": "1.2.3",
    "GIT_SHA": "0123abcd",
    "BUILD_TIME": "2026-11-23T00:00:00Z",
}


def make_client(**overrides: str) -> TestClient:
    return TestClient(create_app(Settings.from_env({**BUILD_ENV, **overrides})))


@pytest.fixture
def client():
    with make_client() as c:  # `with` runs the lifespan (startup/shutdown) hooks
        yield c


def test_health_is_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_ready_after_startup(client):
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_not_ready_before_startup_and_after_shutdown():
    c = make_client()
    assert c.get("/ready").status_code == 503  # lifespan not started yet
    with c:
        assert c.get("/ready").status_code == 200
    assert c.app.state.ready is False  # shutdown hook flipped readiness


def test_version_reports_build_metadata(client):
    assert client.get("/version").json() == {
        "service": "{{service_name}}",
        "version": "1.2.3",
        "git_sha": "0123abcd",
        "build_time": "2026-11-23T00:00:00Z",
        "environment": "dev",
    }


def test_root_summary(client):
    assert client.get("/").json() == {"service": "{{service_name}}", "environment": "dev", "version": "1.2.3"}


def test_security_headers_present(client):
    r = client.get("/health")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"
    assert r.headers["Cache-Control"] == "no-store"


def test_valid_request_id_is_propagated(client):
    r = client.get("/health", headers={"X-Request-ID": "abc-12345678"})
    assert r.headers["X-Request-ID"] == "abc-12345678"


@pytest.mark.parametrize("bad", ["short", "a" * 65, "evil\u2028id-123456", "x;rm -rf /;0000"])
def test_malformed_request_id_is_replaced(client, bad):
    r = client.get("/health", headers={"X-Request-ID": bad.encode("utf-8")})
    assert r.headers["X-Request-ID"] != bad
    assert len(r.headers["X-Request-ID"]) == 36  # uuid4


def test_unknown_route_is_404(client):
    assert client.get("/does-not-exist").status_code == 404


def test_metrics_disabled_by_default(client):
    assert client.get("/metrics").status_code == 404


def test_metrics_when_enabled():
    with make_client(METRICS_ENABLED="true") as c:
        c.get("/health")
        c.get("/nope")
        body = c.get("/metrics").text
    assert 'http_requests_total{method="GET",route="/health",status="200"} 1' in body
    # Unmatched paths are collapsed into one series so scanners cannot explode metric cardinality.
    assert 'route="unmatched",status="404"' in body
    assert "/nope" not in body


def test_docs_disabled_outside_local(client):
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404


def test_docs_enabled_locally():
    with make_client(APP_ENV="local") as c:
        assert c.get("/openapi.json").status_code == 200


def test_unhandled_exception_returns_json_500():
    app = create_app(Settings.from_env(BUILD_ENV))

    @app.get("/boom")
    async def boom():
        raise RuntimeError("kaboom")

    with TestClient(app, raise_server_exceptions=False) as c:
        r = c.get("/boom")
    assert r.status_code == 500
    assert r.json()["error"] == "internal_error"
    assert "kaboom" not in r.text  # no internals leaked to the client


def test_request_logs_are_structured_json(capsys):
    with make_client() as c:
        capsys.readouterr()
        c.get("/version", headers={"X-Request-ID": "req-00000001"})
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line.startswith("{")]
    request_logs = [x for x in lines if x.get("message") == "request"]
    assert request_logs, lines
    entry = request_logs[0]
    assert entry["request_id"] == "req-00000001"
    assert entry["path"] == "/version"
    assert entry["status"] == 200
    assert entry["service"] == "{{service_name}}"
    assert entry["level"] == "INFO"
    assert isinstance(entry["duration_ms"], float)


def test_successful_health_checks_are_not_logged_at_info(capsys):
    with make_client() as c:
        capsys.readouterr()
        c.get("/health")
    assert '"path":"/health"' not in capsys.readouterr().out


def test_shutdown_is_logged(capsys):
    with make_client():
        pass
    out = capsys.readouterr().out
    assert '"event":"shutdown"' in out


@pytest.mark.parametrize(
    ("env", "field", "expected"),
    [
        ({"APP_ENV": "PROD"}, "environment", "prod"),
        ({"APP_ENV": "moon"}, "environment", "local"),
        ({"LOG_LEVEL": "verbose"}, "log_level", "INFO"),
        ({"APP_VERSION": "1.0.0\nINJECTED"}, "version", "0.0.0-dev"),
        ({"METRICS_ENABLED": "yes"}, "metrics_enabled", True),
        ({}, "docs_enabled", True),
        ({"APP_ENV": "prod"}, "docs_enabled", False),
    ],
)
def test_settings_are_sanitised(env, field, expected):
    assert getattr(Settings.from_env(env), field) == expected


def teardown_module():
    logging.getLogger().handlers[:] = []
