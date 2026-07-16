#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCHEMA="$ROOT/skills/git-workflow-standard/references/release-evidence-v1.schema.json"
PROFILE="$ROOT/skills/observability-standard/references/conformance-profile-v2.json"

python3 - "$SCHEMA" "$PROFILE" <<'PY'
import json
import re
import sys

schema = json.load(open(sys.argv[1]))
profile = json.load(open(sys.argv[2]))
properties = schema["properties"]
required = {"schema_version", "service.version", "git_sha", "image_digest"}
version_pattern = "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"
placeholders = ["dev", "Dev", "DEV", "latest", "Latest", "LATEST", "unknown", "Unknown", "UNKNOWN"]

assert set(schema) == {"$schema", "$id", "title", "type", "additionalProperties", "required", "properties"}
assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
assert schema["$id"] == "urn:evolab:release-evidence:v1"
assert schema["title"] == "Release Evidence v1"
assert schema["type"] == "object"
assert schema["additionalProperties"] is False
assert set(schema["required"]) == required
assert set(properties) == required | {"config_repo_revision", "work_items"}
assert properties["schema_version"] == {"const": "release-evidence/v1"}
assert properties["service.version"] == {
    "type": "string",
    "pattern": version_pattern,
    "not": {"enum": placeholders},
}
assert properties["git_sha"] == {"type": "string", "pattern": "^[0-9a-f]{40}([0-9a-f]{24})?$"}
assert properties["image_digest"] == {"type": "string", "pattern": "^sha256:[0-9a-f]{64}$"}
assert properties["config_repo_revision"] == properties["git_sha"]
assert properties["work_items"] == {
    "type": "array",
    "items": {"type": "string", "minLength": 1},
    "uniqueItems": True,
}
assert profile["service_version_pattern"] == properties["service.version"]["pattern"]
assert profile["forbidden_service_versions"] == properties["service.version"]["not"]["enum"]

def valid(doc):
    if not isinstance(doc, dict) or required - doc.keys() or doc.keys() - properties.keys():
        return False
    if doc["schema_version"] != properties["schema_version"]["const"]:
        return False
    version = doc["service.version"]
    rule = properties["service.version"]
    if not isinstance(version, str) or not re.fullmatch(rule["pattern"], version):
        return False
    if version in rule["not"]["enum"]:
        return False
    for key in ("git_sha", "image_digest", "config_repo_revision"):
        if key in doc:
            rule = properties[key]
            if not isinstance(doc[key], str) or not re.fullmatch(rule["pattern"], doc[key]):
                return False
    if "work_items" in doc:
        items = doc["work_items"]
        if not isinstance(items, list) or any(not isinstance(item, str) or not item for item in items):
            return False
        if len(items) != len(set(items)):
            return False
    return True

good = {
    "schema_version": "release-evidence/v1",
    "service.version": "v1.5.2",
    "git_sha": "a" * 40,
    "image_digest": "sha256:" + "b" * 64,
    "config_repo_revision": "c" * 40,
    "work_items": ["PLAT-123", "PLAT-128"],
}
assert valid(good)
assert valid({key: good[key] for key in schema["required"]})
for tag in ("20260716-1430-a1b2c3d", "v1.5.2", "1.5.2", "sha-a1b2c3d", "manual-20260708-4b38eb7", "a" * 128):
    assert valid(good | {"service.version": tag}), tag

for version in ("", "dev", "LATEST", "unknown", "a/b", "a:b", "版本1", "\0", "a" * 129, " v1.5.2", "v1.5.2 ", 123):
    assert not valid(good | {"service.version": version}), repr(version)
for patch in (
    {"config_repo_revision": "short"},
    {"work_items": [""]},
    {"work_items": ["PLAT-123", "PLAT-123"]},
    {"release_id": "parallel-id"},
):
    assert not valid(good | patch), patch
assert not valid({key: value for key, value in good.items() if key != "image_digest"})
assert not valid([])

print("release evidence contract: exact schema + positive/negative controls clean")
PY
