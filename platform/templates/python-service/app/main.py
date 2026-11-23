"""Sample API: the reference workload deployed by the Internal Developer Platform.

Endpoints
  GET /          service summary
  GET /health    liveness: the process is up and serving (ALB target-group + container health check)
  GET /ready     readiness: the service is willing to take traffic (503 while starting/shutting down)
  GET /version   build metadata of the running image
  GET /metrics   Prometheus text format, only when METRICS_ENABLED=true

Graceful shutdown: ECS sends SIGTERM, then SIGKILL after the task's stopTimeout. Uvicorn stops
accepting connections and drains in-flight requests on SIGTERM (bounded by
--timeout-graceful-shutdown, set below stopTimeout in the Dockerfile); the lifespan hook marks the
service not-ready and logs the shutdown so it is visible in CloudWatch.
"""

from __future__ import annotations

import logging
import re
import time
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, PlainTextResponse

from .config import Settings
from .logging_setup import configure_logging
from .metrics import RequestMetrics

logger = logging.getLogger("{{service_module}}")

_REQUEST_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")
_SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging(settings.log_level, settings.service_name, settings.environment, settings.version)
    metrics = RequestMetrics()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.ready = True
        logger.info("startup complete", extra={"event": "startup", "git_sha": settings.git_sha})
        yield
        app.state.ready = False
        logger.info("shutdown signal received, draining", extra={"event": "shutdown"})

    app = FastAPI(
        title=settings.service_name,
        version=settings.version,
        lifespan=lifespan,
        docs_url="/docs" if settings.docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if settings.docs_enabled else None,
    )
    app.state.ready = False
    app.state.settings = settings

    @app.middleware("http")
    async def observe(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        incoming = request.headers.get("x-request-id", "")
        request_id = incoming if _REQUEST_ID.match(incoming) else str(uuid.uuid4())
        start = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            logger.exception("unhandled error", extra={"request_id": request_id, "path": request.url.path})
            response = JSONResponse({"error": "internal_error", "request_id": request_id}, status_code=500)
        duration = time.perf_counter() - start

        route = request.scope.get("route")
        route_path = getattr(route, "path", "unmatched")
        metrics.observe(request.method, route_path, response.status_code, duration)
        response.headers["X-Request-ID"] = request_id
        for name, value in _SECURITY_HEADERS.items():
            response.headers.setdefault(name, value)

        # Health checks run every few seconds; keep them out of INFO logs to save CloudWatch ingest cost.
        quiet = route_path in {"/health", "/ready"} and response.status_code < 400
        logger.log(
            logging.DEBUG if quiet else logging.INFO,
            "request",
            extra={
                "request_id": request_id,
                "method": request.method,
                "path": route_path,
                "status": response.status_code,
                "duration_ms": round(duration * 1000, 2),
            },
        )
        return response

    @app.get("/")
    async def root() -> dict[str, str]:
        return {"service": settings.service_name, "environment": settings.environment, "version": settings.version}

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready")
    async def ready(request: Request) -> JSONResponse:
        if request.app.state.ready:
            return JSONResponse({"status": "ready"})
        return JSONResponse({"status": "not_ready"}, status_code=503)

    @app.get("/version")
    async def version() -> dict[str, str]:
        return {
            "service": settings.service_name,
            "version": settings.version,
            "git_sha": settings.git_sha,
            "build_time": settings.build_time,
            "environment": settings.environment,
        }

    if settings.metrics_enabled:

        @app.get("/metrics", response_class=PlainTextResponse)
        async def prometheus_metrics() -> PlainTextResponse:
            return PlainTextResponse(metrics.render(), media_type="text/plain; version=0.0.4")

    return app


app = create_app()
