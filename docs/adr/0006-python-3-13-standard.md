# ADR 0006: Python 3.13 is the project standard; no automatic minor-version upgrades

- **Status:** Accepted (owner decision, 2026-11-23)
- **Date:** 2026-11-23

## Context

Dependabot PR #2 moved the container base image from `python:3.13-slim` to `python:3.15-slim`.
Everything else stayed on 3.13: the service manifest schema (`runtime: python3.13`), the CI
test interpreter and `pyproject.toml`. CI still passed, because the container's smoke test does not
run the unit tests. The tested version and the shipped version had silently diverged. A Python
minor upgrade changes the language, the standard library and binary wheels (ABI `cp313` →
`cp315`). It should be a deliberate migration, not a routine dependency bump.

## Decision

1. **Python 3.13 everywhere:**
   - the Dockerfile (both stages, digest-pinned `python:3.13-slim`);
   - CI (`PYTHON_VERSION: "3.13"`, the latest 3.13.x patch on each run);
   - `pyproject.toml` (`requires-python = ">=3.13,<3.14"`, Ruff `py313`);
   - `.python-version`;
   - the Codespaces dev container (`mcr.microsoft.com/devcontainers/python:1-3.13-bookworm`);
   - the service manifest schema (`runtime` enum `python3.13`).
2. **Dependabot** (`docker` ecosystem) ignores `version-update:semver-major` and
   `version-update:semver-minor` for `python`. It still proposes **digest refreshes** of
   `python:3.13-slim`, which carry Python 3.13 patch releases and Debian security fixes, and every
   such PR passes the full CI gate, including the Trivy image scan. Python packages (`pip`) keep their
   normal patch/minor updates, because they are tested on 3.13 by CI.
3. `tests/platform/test_repo_hygiene.py` asserts all of the above. Replaying PR #2's change, or
   loosening the Dependabot rule, or changing CI's interpreter, fails CI (verified 2026-11-23).

## Dependency verification (2026-11-23, before the change)

- Every runtime and dev pin, with all transitive dependencies (36 distributions), resolves for
  **CPython 3.13 using wheels only** (`pip download --only-binary=:all: --python-version 3.13 --abi cp313`)
  on **both linux/x86_64 and linux/arm64**. The CI-only linters (`actionlint-py`, `zizmor`,
  `checkov`) were checked through PyPI metadata and run on 3.13 in CI.
- The compiled packages have `cp313` wheels: `pydantic-core` 2.50.5, `PyYAML` 6.0.3, `rpds-py`
  2026.9.1 and `coverage` 7.17.4. `ruff` and `zizmor` ship Python-independent binary wheels.
- Declared support (PyPI `requires_python`): every pin accepts 3.13. `httpx` 0.28.1 lacks a 3.13
  classifier but is pure Python and is exercised by the test suite on 3.13.18 in CI. `actionlint-py`
  only wraps a Go binary.
- Base image: the latest `python:3.13-slim` is still Python **3.13.18**, multi-architecture index
  digest `sha256:e48f59cd…`. It is the same image CI built, smoke-tested and Trivy-scanned in the
  Phase 2 runs.

## Consequences

- A move to Python 3.14/3.15 is a planned change: bump all the locations above in one PR, update
  the schema enum and the hygiene test's `PYTHON_STANDARD`, and re-run the wheel verification.
- Python 3.13 (PEP 719) is in its security-fix phase: regular bug-fix releases ended around
  October 2026, and security releases continue until October 2029. The standard is therefore
  supported for the life of this project. Revisit it before the end of 2028 at the latest.
