# syntax=docker/dockerfile:1
# Multi-stage build: dependencies are installed in a throwaway builder stage, and only the virtualenv
# and application code are copied into the runtime image (no compilers, no pip, no build caches).
#
# The base image is pinned by digest (immutable), not just by tag, and is deliberately NOT a build
# argument: nothing at build time can swap the base image. Dependabot/Renovate (Phase 2) proposes
# digest bumps through pull requests so OS patches still arrive, but only after CI scans them.

FROM python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN set -eux \
    && /opt/venv/bin/pip install -r /tmp/requirements.txt \
    && { /opt/venv/bin/pip uninstall -y pip setuptools wheel || true; }

FROM python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS runtime
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown
LABEL org.opencontainers.image.title="sample-api" \
      org.opencontainers.image.source="https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_TIME}"

# Patch OS packages at build time. `--error-on=any` makes an unreachable mirror FAIL the build; by
# default apt only warns, and the upgrade then silently patches nothing (found in Phase 1 validation).
# pip is removed from the runtime image: nothing installs packages at runtime, and pip is a frequent
# source of scanner findings.
RUN set -eux \
    && apt-get update --error-on=any \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && { python -m pip uninstall -y pip setuptools wheel 2>/dev/null || true; } \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    BUILD_TIME=${BUILD_TIME} \
    PORT=8080

COPY --from=builder /opt/venv /opt/venv
WORKDIR /srv
COPY --chown=root:root app ./app

# Numeric UID so ECS/Kubernetes "runAsNonRoot" checks can verify it without /etc/passwd.
USER 10001:10001
EXPOSE 8080

# Container-level health check (ECS also defines its own; the ALB checks /health independently).
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"]

# Exec form: uvicorn is PID 1 and receives SIGTERM directly. Graceful-shutdown timeout (20s) is below
# the ECS stopTimeout (30s) so in-flight requests drain before SIGKILL.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--timeout-graceful-shutdown", "20", "--no-server-header"]
