#!/usr/bin/env python3
"""Create a new service from the platform's golden-path template (self-service, Phase 6).

    scripts/new_service.py <name> --owner <team> --description "<what it does>"

Copies platform/templates/python-service to apps/<name>, fills in the name, owner and description,
validates the resulting manifest against the same schema and policy as CI, and regenerates the
service catalog. Nothing is deployed: the new service reaches AWS only through the reviewed
pipeline (pull request, image-build, approved app-deploy).

The template IS the reference service: rendering it with sample-api's values must reproduce
apps/sample-api exactly (tests/platform/test_new_service.py), so the template cannot drift from
the code that is actually built, scanned and deployed.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

import yaml
from generate_catalog import write_catalog
from validate_service import ROOT, load_policy, load_schema, policy_errors, schema_errors

TEMPLATE_DIR = ROOT / "platform" / "templates" / "python-service"
NAME_PATTERN = re.compile(r"^[a-z](?!.*--)[a-z0-9-]{1,18}[a-z0-9]$")  # same rule as the schema
SKIP = {"__pycache__", ".pytest_cache", ".coverage"}


def render_file(text: str, name: str, owner: str, description: str) -> str:
    return (
        text.replace('"{{description}}"', json.dumps(description))
        .replace("{{description}}", description)
        .replace("{{owner}}", owner)
        .replace("{{service_name}}", name)
        .replace("{{service_module}}", name.replace("-", "_"))
    )


def render_tree(target: Path, name: str, owner: str, description: str, template: Path = TEMPLATE_DIR) -> list[Path]:
    """Write the rendered template to `target` (which must not exist). Returns the files written."""
    written = []
    for src in sorted(template.rglob("*")):
        rel = src.relative_to(template)
        if any(part in SKIP for part in rel.parts) or not src.is_file():
            continue
        dst = target / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(render_file(src.read_text(encoding="utf-8"), name, owner, description), encoding="utf-8")
        shutil.copymode(src, dst)
        written.append(dst)
    return written


def check_inputs(name: str, owner: str, description: str, apps_dir: Path) -> list[str]:
    errors = []
    if not NAME_PATTERN.match(name):
        errors.append(f"name {name!r}: 3-20 lowercase letters, digits or single hyphens, starting with a letter")
    if (apps_dir / name).exists():
        errors.append(f"{(apps_dir / name).as_posix()} already exists")
    if any(c in description for c in '\n\r"\\'):
        errors.append("description must be one line without quotes or backslashes")
    # Everything else (approved team, reserved name, description length) is the manifest validator's job.
    template = (TEMPLATE_DIR / "service.yaml").read_text(encoding="utf-8")
    manifest = yaml.safe_load(render_file(template, name, owner, description))
    found = schema_errors(manifest, load_schema())
    return errors + (found or policy_errors(manifest, load_policy()))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("name", help="service name, e.g. orders-api")
    parser.add_argument("--owner", required=True, help="owning team (must be an approved team), e.g. team-payments")
    parser.add_argument("--description", required=True, help="one sentence, 10-200 characters")
    parser.add_argument("--apps-dir", type=Path, default=ROOT / "apps", help=argparse.SUPPRESS)  # tests
    parser.add_argument("--no-catalog", action="store_true", help=argparse.SUPPRESS)  # tests
    args = parser.parse_args(argv)

    errors = check_inputs(args.name, args.owner, args.description, args.apps_dir)
    if errors:
        print("cannot create the service:\n  " + "\n  ".join(errors), file=sys.stderr)
        return 1

    target = args.apps_dir / args.name
    files = render_tree(target, args.name, args.owner, args.description)
    print(f"created {target.as_posix()} ({len(files)} files) from {TEMPLATE_DIR.relative_to(ROOT).as_posix()}")
    if not args.no_catalog:
        for path in write_catalog():
            print(f"updated {path.relative_to(ROOT).as_posix()}")
    print(
        "\nNext steps:\n"
        f"  1. make test-apps          # the new service's own tests (90% coverage gate)\n"
        f"  2. edit apps/{args.name}/app/main.py, keep /health, /ready and /version\n"
        "  3. open a pull request: CI must pass (ci-ok) before merge\n"
        "  4. deployment to AWS needs platform onboarding (ECR repository + environment stack):\n"
        "     open a 'Deploy request' issue; see docs/developer-guide.md section 5"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
