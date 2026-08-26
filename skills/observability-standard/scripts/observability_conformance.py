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


def walk_pairs(value: Any) -> list[tuple[str, Any]]:
    pairs: list[tuple[str, Any]] = []
    if isinstance(value, dict):
        for key, child in value.items():
            pairs.append((str(key), child))
            pairs.extend(walk_pairs(child))
    elif isinstance(value, list):
        for child in value:
            pairs.extend(walk_pairs(child))
    return pairs


def content_key_hit(candidate: str, content_keys: list[str]) -> str | None:
    for key in content_keys:
        if candidate == key or candidate.startswith(f"{key}."):
            return key
    return None


def collect_strings(value: Any) -> list[str]:
    texts: list[str] = []
    if isinstance(value, str):
        texts.append(value)
    elif isinstance(value, dict):
        for child in value.values():
            texts.extend(collect_strings(child))
    elif isinstance(value, list):
        for child in value:
            texts.extend(collect_strings(child))
    return texts


SCHEMA_V2 = "observability-conformance/v2"
SCHEMA_V3 = "observability-conformance/v3"
CONTENT_CAPTURE_KEYS = (
    "flag_field", "environment_resource_key", "allowed_environment_pattern",
    "redaction_probe", "audit_sink",
)
REDACTION_PROBE_KEYS = (
    "field", "canary_field", "canary_class_field", "canary_value_field", "output_field",
    "required_canary_classes", "min_output_chars", "forbidden_output_patterns",
)
AUDIT_SINK_KEYS = ("field", "hash_value_pattern", "metadata_key_allowlist", "metadata_max_length")


def check_profile(profile: dict[str, Any]) -> list[str]:
    """Dispatch is decided by the declared schema_version alone. An unknown version, a v3
    missing any part of the content-capture contract, or a v2 carrying such a section at
    all, is an invalid profile — never a silently loosened one."""
    errors: list[str] = []
    version = profile.get("schema_version")
    if version not in (SCHEMA_V2, SCHEMA_V3):
        fail(errors, "profile.schema_version_unknown", str(version))
        return errors
    cfg = profile.get("content_capture")
    if version == SCHEMA_V2:
        if cfg is not None:
            fail(errors, "profile.content_capture_unexpected", SCHEMA_V2)
        return errors
    if not isinstance(cfg, dict):
        fail(errors, "profile.content_capture_incomplete", "content_capture")
        return errors
    for key in CONTENT_CAPTURE_KEYS:
        if key not in cfg:
            fail(errors, "profile.content_capture_incomplete", key)
    probe_cfg = cfg.get("redaction_probe")
    if isinstance(probe_cfg, dict):
        for key in REDACTION_PROBE_KEYS:
            if key not in probe_cfg:
                fail(errors, "profile.content_capture_incomplete", f"redaction_probe.{key}")
        patterns = probe_cfg.get("forbidden_output_patterns")
        classes = probe_cfg.get("required_canary_classes")
        if isinstance(patterns, dict) and isinstance(classes, list):
            # a required class with no shape shuts the canary-shape assertion off silently
            for canary_class in classes:
                if canary_class not in patterns:
                    fail(errors, "profile.canary_class_without_pattern", str(canary_class))
    elif "redaction_probe" in cfg:
        fail(errors, "profile.content_capture_incomplete", "redaction_probe")
    audit_cfg = cfg.get("audit_sink")
    if isinstance(audit_cfg, dict):
        for key in AUDIT_SINK_KEYS:
            if key not in audit_cfg:
                fail(errors, "profile.content_capture_incomplete", f"audit_sink.{key}")
    elif "audit_sink" in cfg:
        fail(errors, "profile.content_capture_incomplete", "audit_sink")
    return errors


def check_redaction_probe(
    probe: Any, probe_profile: dict[str, Any]
) -> tuple[list[str], bool, list[tuple[str, str]]]:
    """Assert a real redaction probe: shape-carrying canaries in, index-aligned non-empty
    redacted text out, and no canary literal (nor secret-shaped text) surviving the output."""
    errors: list[str] = []
    if not isinstance(probe, dict):
        fail(errors, "content.redaction_probe_malformed", type(probe).__name__)
        return errors, False, []
    raw_canaries = probe.get(probe_profile["canary_field"])
    canaries: list[tuple[str, str]] = []
    if not isinstance(raw_canaries, list) or not raw_canaries:
        fail(errors, "content.redaction_canaries_missing", "probe must declare input canaries")
        raw_canaries = []
    for entry in raw_canaries:
        canary_class = entry.get(probe_profile["canary_class_field"]) if isinstance(entry, dict) else None
        canary_value = entry.get(probe_profile["canary_value_field"]) if isinstance(entry, dict) else None
        if not isinstance(canary_class, str) or not canary_class or not isinstance(canary_value, str) or not canary_value:
            fail(errors, "content.redaction_canary_malformed", str(canary_class))
            continue
        canaries.append((canary_class, canary_value))
    declared_classes = {canary_class for canary_class, _ in canaries}
    patterns = probe_profile["forbidden_output_patterns"]
    for canary_class in probe_profile["required_canary_classes"]:
        if canary_class not in declared_classes:
            fail(errors, "content.redaction_canary_class_missing", str(canary_class))
            continue
        # a canary that does not look like the thing it stands for tests nothing
        shape = patterns[canary_class]
        for declared, value in canaries:
            if declared == canary_class and not re.search(shape, value):
                fail(errors, "content.redaction_canary_shape", str(canary_class))
    outputs = probe.get(probe_profile["output_field"])
    if not isinstance(outputs, list) or len(outputs) != len(raw_canaries):
        produced = len(outputs) if isinstance(outputs, list) else type(outputs).__name__
        fail(errors, "content.redaction_output_arity", f"{len(raw_canaries)} canaries vs {produced} redacted")
        outputs = outputs if isinstance(outputs, list) else []
    for index, produced in enumerate(outputs):
        if not isinstance(produced, str) or len(produced.strip()) < probe_profile["min_output_chars"]:
            fail(errors, "content.redaction_output_empty", f"redacted[{index}]")
    texts = [produced for produced in outputs if isinstance(produced, str)]
    for canary_class, canary_value in canaries:
        for index, produced in enumerate(texts):
            if canary_value in produced:
                fail(errors, "content.redaction_canary_leak", f"{canary_class} survived into redacted[{index}]")
                break
    for name, pattern in patterns.items():
        for index, produced in enumerate(texts):
            if re.search(pattern, produced):
                fail(errors, "content.redaction_pattern_leak", f"{name} shape in redacted[{index}]")
                break
    return errors, not errors, canaries


def check_content_capture(
    snapshot: dict[str, Any],
    resource: dict[str, Any],
    profile: dict[str, Any],
) -> list[str]:
    """v3 conditional capture: content keys ride only on an explicit runtime flag, an
    allowlisted non-production environment, and redaction evidence that is tied to the
    captured content itself. Audit/persistent evidence stays hash-only."""
    errors: list[str] = []
    cfg = profile["content_capture"]
    probe_profile = cfg["redaction_probe"]
    audit_field = cfg["audit_sink"]["field"]
    probe = snapshot.get(probe_profile["field"])
    probe_ok = False
    canaries: list[tuple[str, str]] = []
    if probe is not None:
        probe_errors, probe_ok, canaries = check_redaction_probe(probe, probe_profile)
        errors.extend(probe_errors)

    # hash-only audit evidence is governed by its own rule below, not by the capture gate
    capture_view = {key: value for key, value in snapshot.items() if key != audit_field}
    capture_keys = walk_keys(capture_view)
    present_keys = [
        key for key in profile["content_keys"]
        if any(found == key or found.startswith(f"{key}.") for found in capture_keys)
    ]
    captured: list[tuple[str, str]] = []
    for key, value in walk_pairs(capture_view):
        if content_key_hit(key, profile["content_keys"]) is not None:
            captured.extend((key, text) for text in collect_strings(value))

    if present_keys:
        detail = ",".join(present_keys)
        if snapshot.get(cfg["flag_field"]) is not True:
            fail(errors, "content.capture_not_enabled", detail)
        environment = resource.get(cfg["environment_resource_key"])
        if not isinstance(environment, str) or not environment.strip():
            fail(errors, "content.capture_environment_unknown", detail)
        elif not re.fullmatch(cfg["allowed_environment_pattern"], environment.strip(), re.IGNORECASE):
            fail(errors, "content.capture_forbidden_environment", environment)
        if probe is None:
            fail(errors, "content.redaction_evidence_missing", detail)
        elif not probe_ok:
            fail(errors, "content.redaction_evidence_unproven", detail)

    # binds the probe to the capture path: an unwired redactor lets the canary through here
    for canary_class, canary_value in canaries:
        hit = next((key for key, text in captured if canary_value in text), None)
        if hit is not None:
            fail(errors, "content.capture_canary_leak", f"{canary_class} in captured {hit}")

    audit_cfg = cfg["audit_sink"]
    records = snapshot.get(audit_cfg["field"])
    if records is not None:
        allowlist = audit_cfg["metadata_key_allowlist"]
        max_length = audit_cfg["metadata_max_length"]
        for key, value in walk_pairs(records):
            if not isinstance(value, str) or re.fullmatch(audit_cfg["hash_value_pattern"], value):
                continue
            if key in allowlist:
                if len(value) > max_length:
                    fail(errors, "content.audit_metadata_too_long", key)
                continue
            fail(errors, "content.audit_not_hashed", key)
    return errors


def validate(snapshot: dict[str, Any], profile: dict[str, Any]) -> list[str]:
    errors: list[str] = check_profile(profile)
    if errors:
        # an unidentifiable profile decides nothing about the snapshot
        return errors
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
        elif re.fullmatch(profile["forbidden_service_version_pattern"], service_version):
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
    if profile["schema_version"] == SCHEMA_V3:
        errors.extend(check_content_capture(snapshot, resource, profile))
    else:
        for key in profile["content_keys"]:
            if any(found == key or found.startswith(f"{key}.") for found in all_keys):
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
