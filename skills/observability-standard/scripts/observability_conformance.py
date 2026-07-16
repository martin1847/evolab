#!/usr/bin/env python3
"""Validate a normalized observability snapshot against a versioned profile."""

from __future__ import annotations

import argparse
import json
import re
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
    service_version = resource.get("service.version")
    if service_version is not None:
        if not isinstance(service_version, str):
            fail(errors, "resource.service_version_type", type(service_version).__name__)
        elif not re.fullmatch(profile["service_version_pattern"], service_version):
            fail(errors, "resource.service_version_shape", service_version)
        elif service_version in profile.get("forbidden_service_versions", []):
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
        for key, allowed in profile.get("custom_attribute_allowlists", {}).items():
            value = attrs.get(key)
            if value is not None and (
                not isinstance(value, str)
                or len(value) > profile["custom_attribute_max_length"]
                or value not in allowed
            ):
                fail(errors, "custom_attribute.allowlist", f"{key}={value}")
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
        if span.get("streaming"):
            if span.get("stream_completed") and span.get("status") != "success":
                fail(errors, "stream.completed_status", str(span.get("span_id")))
            if not span.get("stream_completed") and span.get("status") not in {"error", "cancelled"}:
                fail(errors, "stream.invalid_terminal_state", str(span.get("span_id")))

    metric_labels = snapshot.get("metric_label_keys", [])
    for key in profile.get("metric_label_forbidden_keys", []):
        if key in metric_labels:
            fail(errors, "metric.high_cardinality", key)

    if snapshot.get("gen_ai_enabled", False):
        async_spans = [span for span in spans if span.get("async_boundary")]
        if not async_spans:
            fail(errors, "async.evidence_missing", "captured worker/callback span is required")
        for span in async_spans:
            if not span.get("parent_span_id"):
                fail(errors, "async.parent", str(span.get("span_id")))
            if span.get("context_restored") is not True:
                fail(errors, "async.context_not_restored", str(span.get("span_id")))
        chain_spans = [
            span for span in spans
            if span.get("role") in {"domain", "inference"} or span.get("async_boundary")
        ]
        for key in profile.get("consistent_trace_attributes", []):
            for trace_id in {span.get("trace_id") for span in chain_spans}:
                values = {
                    span.get("attributes", {}).get(key)
                    for span in chain_spans if span.get("trace_id") == trace_id
                }
                if None in values or "" in values or len(values) != 1:
                    fail(errors, "custom_attribute.inconsistent", f"{key}={sorted(str(value) for value in values)}")
        guard = snapshot.get("static_guard", {})
        producers = guard.get("semantic_producers", [])
        if producers != [profile["approved_semantic_producer"]]:
            fail(errors, "static_guard.semantic_producer", str(producers))
        for key in ("vendor_or_legacy_paths", "arbitrary_metadata_flatteners"):
            if guard.get(key) != []:
                fail(errors, f"static_guard.{key}", str(guard.get(key)))

    all_keys = walk_keys(snapshot)
    telemetry_keys = walk_keys(resource)
    for span in spans:
        telemetry_keys.update(walk_keys(span.get("attributes", {})))
    for key in profile["forbidden_keys"]:
        if key in telemetry_keys:
            fail(errors, "legacy.key", key)
    for prefix in profile.get("forbidden_key_prefixes", []):
        for key in all_keys:
            if key.startswith(prefix):
                fail(errors, "legacy.key_prefix", key)
    for key in profile["content_keys"]:
        present = any(found == key or found.startswith(f"{key}.") for found in all_keys)
        if present:
            fail(errors, "content.leak", key)
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
