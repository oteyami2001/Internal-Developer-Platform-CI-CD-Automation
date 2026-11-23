# Rollback drill image (Phase 7). Built, scanned and published by the pipeline like a release
# (drill-image.yml, tag drill-crash-<commit>), but the container exits immediately with status 1.
# Deploying it with app-deploy MUST fail: ECS cannot start a healthy task, the deployment circuit
# breaker marks it FAILED and rolls the service back to the previous revision while the old task
# keeps serving (minimumHealthyPercent 100). It never contains application code.
FROM python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90
LABEL org.opencontainers.image.title="rollback-drill-crash-on-start" \
      org.opencontainers.image.source="https://github.com/oteyami2001/Internal-Developer-Platform-CI-CD-Automation"
USER 10001:10001
HEALTHCHECK --interval=15s --timeout=3s --retries=1 CMD ["python", "-c", "raise SystemExit(1)"]
CMD ["python", "-c", "import sys; print('rollback drill: exiting on purpose', flush=True); sys.exit(1)"]
