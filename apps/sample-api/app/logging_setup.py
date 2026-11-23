"""Structured JSON logging.

One JSON object per line on stdout. ECS ships stdout to CloudWatch Logs (awslogs driver), where
Logs Insights can query fields directly, e.g. `filter status >= 500 | stats count() by path`.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime

# Attributes every LogRecord has; anything else was passed through `extra=` and is emitted as a field.
_RESERVED = set(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {"message", "asctime", "color_message"}


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str, environment: str, version: str) -> None:
        super().__init__()
        self._static = {"service": service, "environment": environment, "version": version}

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            **self._static,
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str, separators=(",", ":"))


def configure_logging(level: str, service: str, environment: str, version: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service, environment, version))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    # Uvicorn's access log duplicates our request log in an unstructured format.
    logging.getLogger("uvicorn.access").disabled = True
    for name in ("uvicorn", "uvicorn.error"):
        logging.getLogger(name).handlers[:] = []
        logging.getLogger(name).propagate = True
