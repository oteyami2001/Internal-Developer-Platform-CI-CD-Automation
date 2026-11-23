# ADR 0004: Generated static service catalog instead of a developer-portal server

- **Status:** Accepted (Phase 1 proposal)
- **Date:** 2026-11-23

## Context
A Backstage deployment needs compute, a database and maintenance: roughly $30–$100/month and
ongoing upgrades. For a demo platform with a handful of services, that cost exceeds its value.

## Decision
`scripts/generate_catalog.py` builds `platform/catalog/services.yaml` from the validated
`apps/*/service.yaml` manifests. The file is committed, and CI runs `--check` so the catalog can
never be stale. The format is intentionally close to a Backstage `Component` entity, so a portal
can ingest it later.

## Consequences
- Zero runtime cost; the catalog is reviewable in PRs and versioned with the code.
- No interactive UI. GitHub renders the YAML and docs; a static HTML page is a possible Phase 6 add-on.
