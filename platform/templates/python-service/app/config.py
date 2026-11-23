"""Runtime configuration, read once from environment variables.

Every value has a safe default so the service starts locally with no configuration. Values that
identify the build (version, git SHA, build time) are injected by the image build, never typed by
hand, so `/version` always describes the exact image that is running.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

_LOG_LEVELS = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
_ENVIRONMENTS = {"local", "dev", "staging", "prod"}
_SAFE_VALUE = re.compile(r"^[A-Za-z0-9._:+-]{1,64}$")


def _bool(value: str | None, default: bool) -> bool:
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _safe(value: str | None, default: str) -> str:
    """Metadata ends up in logs and responses: accept only short, printable tokens."""
    if value and _SAFE_VALUE.match(value):
        return value
    return default


@dataclass(frozen=True)
class Settings:
    service_name: str
    environment: str
    version: str
    git_sha: str
    build_time: str
    log_level: str
    metrics_enabled: bool
    docs_enabled: bool

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> Settings:
        e = os.environ if env is None else env
        environment = e.get("APP_ENV", "local").lower()
        if environment not in _ENVIRONMENTS:
            environment = "local"
        log_level = e.get("LOG_LEVEL", "INFO").upper()
        if log_level not in _LOG_LEVELS:
            log_level = "INFO"
        return cls(
            service_name=_safe(e.get("SERVICE_NAME"), "{{service_name}}"),
            environment=environment,
            version=_safe(e.get("APP_VERSION"), "0.0.0-dev"),
            git_sha=_safe(e.get("GIT_SHA"), "unknown"),
            build_time=_safe(e.get("BUILD_TIME"), "unknown"),
            log_level=log_level,
            metrics_enabled=_bool(e.get("METRICS_ENABLED"), default=False),
            # Interactive API docs are useful locally but are attack surface behind a public ALB.
            docs_enabled=_bool(e.get("DOCS_ENABLED"), default=environment == "local"),
        )
