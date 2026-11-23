#!/usr/bin/env python3
"""Run every service's own test suite (`make test-apps`).

Each apps/<service>/ has its own pyproject.toml (pytest + 90% coverage gate). Services are tested
one at a time, in their own directory and process: every service uses the package name `app`, so
they cannot share one pytest session. A new service is picked up automatically, with no CI change.

Optional: JUNIT_DIR=<dir> writes <dir>/junit-<service>.xml for each service.
"""

from __future__ import annotations

import os

# subprocess runs pytest with a fixed argv (this interpreter), never through a shell.
import subprocess  # nosec B404
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def services(apps_dir: Path = ROOT / "apps") -> list[Path]:
    return sorted(p.parent for p in apps_dir.glob("*/pyproject.toml"))


def main() -> int:
    junit_dir = os.environ.get("JUNIT_DIR")
    found = services()
    if not found:
        print("no services found under apps/", file=sys.stderr)
        return 1
    failed = []
    for svc in found:
        print(f"== {svc.name}", flush=True)
        cmd = [sys.executable, "-m", "pytest", "--cov", "--cov-report=term-missing"]
        if junit_dir:
            cmd.append(f"--junitxml={Path(junit_dir).resolve() / f'junit-{svc.name}.xml'}")
        # Fixed argv: this interpreter + pytest; the only variable part is a path we built ourselves.
        if subprocess.run(cmd, cwd=svc, check=False).returncode != 0:  # noqa: S603  # nosec B603
            failed.append(svc.name)
    if failed:
        print(f"FAILED: {', '.join(failed)}", file=sys.stderr)
        return 1
    print(f"all {len(found)} service test suite(s) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
