#!/usr/bin/env python3
"""Validate a normalized observability snapshot against a versioned profile."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def fail(errors: list[str], code: str, detail: str) -> None:
    errors.append(f"{code}: {detail}")


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def walk_keys(value: Any) -> set[str]:
    keys: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            keys.add(str(key))
            keys.update(walk_keys(child))
    elif isinstance(value, list):
        for child in value:
            keys.update(walk_keys(child))
    return keys


def validate(snapshot: dict[str, Any], profile: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    resource = snapshot.get("resource", {})
    for key in profile["required_resource"]:
        if not resource.get(key):
            fail(errors, "resource.missing", key)
    service_version = str(resource.get("service.version", "")).lower()
    if service_version in profile.get("forbidden_service_versions", []):
        fail(errors, "resource.placeholder", service_version)

    tenant = snapshot.get("tenant", {})
    tenant_id = tenant.get("id")
    tenant_verified = tenant.get("verified", False) is True
    if tenant_id and not tenant_verified:
        fail(errors, "tenant.unverified", str(tenant_id))
    aliases = {resource.get(k) for k in ("service.namespace", "deployment.environment.name", "k8s.namespace.name")}
    if tenant_id and tenant_id in aliases:
        fail(errors, "tenant.namespace_alias", str(tenant_id))
    if resource.get("tenant.id") is not None:
        fail(errors, "tenant.in_resource", str(resource.get("tenant.id")))

    spans = snapshot.get("spans", [])
    if not isinstance(spans, list) or not spans:
        fail(errors, "spans.missing", "normalized snapshot must contain spans")
        spans = []
    by_id = {span.get("span_id"): span for span in spans}
    roles = {span.get("role") for span in spans}
    required_roles = list(profile.get("required_span_roles", []))
    if snapshot.get("gen_ai_enabled", False):
        required_roles.extend(profile.get("gen_ai_required_span_roles", []))
    for role in required_roles:
        if role not in roles:
            fail(errors, "span.role_missing", str(role))
    for span in spans:
        for key in profile.get("required_span_fields", []):
            if not span.get(key):
                fail(errors, "span.field", key)
        parent = span.get("parent_span_id")
        if parent is not None and parent not in by_id:
            fail(errors, "span.orphan", str(span.get("span_id")))
        if parent is not None and by_id.get(parent, {}).get("trace_id") != span.get("trace_id"):
            fail(errors, "span.trace_mismatch", str(span.get("span_id")))
        if not span.get("ended", False):
            fail(errors, "span.unfinished", str(span.get("span_id")))
        attrs = span.get("attributes", {})
        emitted_tenant = attrs.get("tenant.id")
        if emitted_tenant is not None and (not tenant_verified or emitted_tenant != tenant_id):
            fail(errors, "tenant.unverified_emission", str(emitted_tenant))
        operation = attrs.get("gen_ai.operation.name")
        if operation and operation not in profile["allowed_operations"]:
            fail(errors, "gen_ai.operation", str(operation))
        if span.get("role") == "inference":
            if not parent or by_id.get(parent, {}).get("role") not in {"domain", "invocation"}:
                fail(errors, "inference.parent", str(span.get("span_id")))
            for key in profile["required_inference"]:
                if not attrs.get(key):
                    fail(errors, "inference.field", key)
        if span.get("streaming") and not span.get("stream_completed"):
            if span.get("status") not in {"error", "cancelled"}:
                fail(errors, "stream.invalid_terminal_state", str(span.get("span_id")))

    all_keys = walk_keys(snapshot)
    telemetry_keys = walk_keys(resource)
    for span in spans:
        telemetry_keys.update(walk_keys(span.get("attributes", {})))
    for key in profile["forbidden_keys"]:
        if key in telemetry_keys:
            fail(errors, "legacy.key", key)
    for key in profile["content_keys"]:
        present = any(found == key or found.startswith(f"{key}.") for found in all_keys)
        if present and not snapshot.get("content_capture_allowed", False):
            fail(errors, "content.leak", key)
        environment = resource.get("deployment.environment.name")
        if present and environment not in profile.get("content_capture_environments", []):
            fail(errors, "content.environment", str(environment))
    processes = snapshot.get("processes", [])
    if not isinstance(processes, list) or not processes:
        fail(errors, "processes.missing", "bootstrap evidence is required")
        processes = []
    for process in processes:
        if not process.get("instrumentation_bootstrapped", False):
            fail(errors, "bootstrap.missing", str(process.get("name")))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--profile", type=Path, required=True)
    args = parser.parse_args()
    try:
        errors = validate(load(args.snapshot), load(args.profile))
    except (AttributeError, KeyError, OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
        errors = [f"input.invalid: {exc}"]
    print(json.dumps({"ok": not errors, "errors": errors}, ensure_ascii=False, sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
