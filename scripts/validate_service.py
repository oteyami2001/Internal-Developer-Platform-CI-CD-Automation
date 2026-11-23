#!/usr/bin/env python3
"""Validate IDP service manifests (apps/<name>/service.yaml).

Two layers:
  1. JSON Schema (platform/schemas/service.schema.json): structure, types, enums, no unknown fields.
  2. Platform policy (platform/policy/platform-policy.yaml): approved teams, per-environment limits,
     reserved names/tags/variables, secret-looking plain variables, cross-manifest uniqueness.

Usage:
  scripts/validate_service.py apps/*/service.yaml           # validate, exit 1 on any error
  scripts/validate_service.py --render dev apps/x/service.yaml  # print effective config (JSON)
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "platform" / "schemas" / "service.schema.json"
POLICY_PATH = ROOT / "platform" / "policy" / "platform-policy.yaml"

DEFAULTS: dict[str, Any] = {
    "metadata": {"tier": "standard", "tags": {}},
    "spec": {
        "container": {"cpu": 256, "memory": 512},
        "healthCheck": {"path": "/health", "intervalSeconds": 30, "healthyThreshold": 2, "unhealthyThreshold": 3},
        "deployment": {
            "strategy": "rolling",
            "circuitBreakerRollback": True,
            "minimumHealthyPercent": 100,
            "maximumPercent": 200,
        },
        "environmentVariables": {},
        "secrets": [],
    },
}
_SECRET_VALUE_PATTERNS = [
    re.compile(r"(AKIA|ASIA)[A-Z0-9]{16}"),  # AWS access key id
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),  # GitHub tokens
]


class ManifestError(Exception):
    pass


class _UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that rejects duplicate keys.

    Plain YAML keeps the LAST duplicate silently, so a reviewer could approve `cpu: 256` while a
    second `cpu: 1024` further down is what gets deployed.
    """


def _construct_mapping(loader: _UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False) -> dict[Any, Any]:
    seen: set[Any] = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise ManifestError(f"duplicate key {key!r} at line {key_node.start_mark.line + 1}")
        seen.add(key)
    return loader.construct_mapping(node, deep=deep)


_UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)


def load_yaml(path: Path) -> Any:
    try:
        # _UniqueKeyLoader subclasses yaml.SafeLoader (no Python object tags); tested in test_validate_service.
        return yaml.load(path.read_text(encoding="utf-8"), Loader=_UniqueKeyLoader)  # nosec B506  # noqa: S506
    except yaml.YAMLError as exc:
        raise ManifestError(f"invalid YAML: {exc}") from exc


def load_schema() -> dict[str, Any]:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def load_policy() -> dict[str, Any]:
    return load_yaml(POLICY_PATH)


def _merge(defaults: dict[str, Any], value: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(defaults)
    for key, item in value.items():
        out[key] = _merge(out[key], item) if isinstance(item, dict) and isinstance(out.get(key), dict) else item
    return out


def with_defaults(manifest: dict[str, Any]) -> dict[str, Any]:
    merged = _merge(DEFAULTS, manifest)
    for env in merged["spec"]["environments"].values():
        env.setdefault("desiredCount", 1)
    return merged


def schema_errors(manifest: Any, schema: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(manifest), key=lambda e: list(e.absolute_path))
    return [f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}" for e in errors]


def policy_errors(manifest: dict[str, Any], policy: dict[str, Any]) -> list[str]:  # noqa: PLR0912
    m = with_defaults(manifest)
    meta, spec = m["metadata"], m["spec"]
    errors: list[str] = []

    if meta["owner"] not in policy["approved_teams"]:
        errors.append(f"metadata/owner: {meta['owner']!r} is not an approved team")
    if meta["name"] in policy["reserved_service_names"]:
        errors.append(f"metadata/name: {meta['name']!r} is reserved")
    reserved_tags = {t.lower() for t in policy["reserved_tag_keys"]}
    for key in meta["tags"]:
        if key.replace("-", "").lower() in reserved_tags:
            errors.append(f"metadata/tags/{key}: tag is set by the platform and cannot be overridden")

    secret_name = re.compile(policy["secret_like_env_name_pattern"])
    for name, value in spec["environmentVariables"].items():
        if name in policy["reserved_env_vars"] or name.startswith(tuple(policy["reserved_env_prefixes"])):
            errors.append(f"spec/environmentVariables/{name}: reserved by the platform")
        if secret_name.search(name):
            errors.append(f"spec/environmentVariables/{name}: looks like a secret; declare it in spec.secrets")
        if any(p.search(value) for p in _SECRET_VALUE_PATTERNS):
            errors.append(f"spec/environmentVariables/{name}: value looks like a credential")
    plain_names = set(spec["environmentVariables"])
    reserved_prefixes = tuple(policy["reserved_env_prefixes"])
    for item in spec["secrets"]:
        if item["name"] in plain_names:
            errors.append(f"spec/secrets/{item['name']}: also defined as a plain environment variable")
        if item["name"] in policy["reserved_env_vars"] or item["name"].startswith(reserved_prefixes):
            errors.append(f"spec/secrets/{item['name']}: reserved by the platform")

    if spec["healthCheck"]["unhealthyThreshold"] * spec["healthCheck"]["intervalSeconds"] > 180:
        errors.append("spec/healthCheck: unhealthyThreshold x intervalSeconds must be <= 180s to detect failures fast")
    if spec["deployment"]["maximumPercent"] <= spec["deployment"]["minimumHealthyPercent"]:
        errors.append("spec/deployment: maximumPercent must be greater than minimumHealthyPercent")

    cpu, memory = spec["container"]["cpu"], spec["container"]["memory"]
    for env_name, env in spec["environments"].items():
        if not env["enabled"]:
            continue
        limits = policy["environments"][env_name]
        where = f"spec/environments/{env_name}"
        count, max_count = env["desiredCount"], limits["max_desired_count"]
        if count > max_count:
            errors.append(f"{where}/desiredCount: {count} exceeds the {env_name} limit of {max_count}")
        if count < limits.get("min_desired_count", 0):
            errors.append(f"{where}/desiredCount: {env_name} requires at least {limits['min_desired_count']} tasks")
        if cpu > limits["max_cpu"]:
            errors.append(f"spec/container/cpu: {cpu} exceeds the {env_name} limit of {limits['max_cpu']}")
        if memory > limits["max_memory"]:
            errors.append(f"spec/container/memory: {memory} exceeds the {env_name} limit of {limits['max_memory']}")
        if limits.get("require_circuit_breaker") and not spec["deployment"]["circuitBreakerRollback"]:
            errors.append(f"spec/deployment/circuitBreakerRollback: required for {env_name}")
        min_healthy = limits.get("min_healthy_percent")
        if min_healthy is not None and spec["deployment"]["minimumHealthyPercent"] < min_healthy:
            errors.append(f"spec/deployment/minimumHealthyPercent: {env_name} requires >= {min_healthy}")
    return errors


def validate_manifest(
    path: Path, schema: dict[str, Any] | None = None, policy: dict[str, Any] | None = None
) -> tuple[dict[str, Any] | None, list[str]]:
    """Return (manifest, errors). The manifest is None when it could not be parsed."""
    try:
        manifest = load_yaml(path)
    except (ManifestError, OSError) as exc:
        return None, [str(exc)]
    errs = schema_errors(manifest, schema or load_schema())
    if errs:  # policy rules assume a structurally valid document
        return manifest, errs
    errs = policy_errors(manifest, policy or load_policy())
    app_dir = path.resolve().parent
    in_apps_dir = path.name == "service.yaml" and app_dir.parent.name == "apps"
    expected_dir = app_dir.name
    if in_apps_dir and expected_dir != manifest["metadata"]["name"]:
        errs.append(f"metadata/name: must match its directory name {expected_dir!r}")
    return manifest, errs


def validate_all(paths: list[Path]) -> dict[Path, list[str]]:
    schema, policy = load_schema(), load_policy()
    results: dict[Path, list[str]] = {}
    owners: dict[str, Path] = {}
    for path in paths:
        manifest, errs = validate_manifest(path, schema, policy)
        if manifest and not errs:
            name = manifest["metadata"]["name"]
            if name in owners:
                errs.append(f"metadata/name: {name!r} is already used by {owners[name]}")
            owners.setdefault(name, path)
        results[path] = errs
    return results


def render(manifest: dict[str, Any], environment: str) -> dict[str, Any]:
    """Effective, fully-defaulted settings for one environment: the contract handed to Terraform."""
    m = with_defaults(manifest)
    spec = m["spec"]
    env = spec["environments"].get(environment)
    if env is None or not env["enabled"]:
        raise ManifestError(f"service {m['metadata']['name']!r} is not enabled in {environment!r}")
    name = m["metadata"]["name"]
    return {
        "service_name": name,
        "owner": m["metadata"]["owner"],
        "environment": environment,
        "container_port": spec["container"]["port"],
        "cpu": spec["container"]["cpu"],
        "memory": spec["container"]["memory"],
        "desired_count": env["desiredCount"],
        "health_check": spec["healthCheck"],
        "deployment": spec["deployment"],
        "environment_variables": spec["environmentVariables"],
        "secrets": {s["name"]: f"idp/{environment}/{name}/{s['secretName']}" for s in spec["secrets"]},
        "tags": m["metadata"]["tags"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("manifests", nargs="+", type=Path)
    parser.add_argument("--render", metavar="ENV", choices=["dev", "staging", "prod"])
    args = parser.parse_args(argv)

    results = validate_all(args.manifests)
    failed = False
    for path, errs in results.items():
        if errs:
            failed = True
            print(f"FAIL {path}")
            for err in errs:
                print(f"  - {err}")
        else:
            print(f"OK   {path}", file=sys.stderr if args.render else sys.stdout)
    if failed:
        return 1
    if args.render:
        rendered = [render(load_yaml(p), args.render) for p in args.manifests]
        print(json.dumps(rendered[0] if len(rendered) == 1 else rendered, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
