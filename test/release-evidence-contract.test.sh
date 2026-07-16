#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCHEMA="$ROOT/skills/git-workflow-standard/references/release-evidence-v1.schema.json"

python3 - "$SCHEMA" <<'PY'
import json
import re
import sys

schema = json.load(open(sys.argv[1]))
required = set(schema["required"])
properties = schema["properties"]
assert required == {"schema_version", "service.version", "git_sha", "image_digest"}
assert schema["additionalProperties"] is False
assert "release_id" not in properties

def validate(doc):
    if required - doc.keys() or (doc.keys() - properties.keys()):
        return False
    return all(key not in doc or validate_rule(doc[key], rule) for key, rule in properties.items())

def validate_rule(value, rule):
    supported = {"type", "const", "pattern", "minLength", "items", "uniqueItems"}
    assert not (set(rule) - supported), f"unhandled schema keywords: {set(rule) - supported}"
    expected = rule.get("type")
    if expected == "string" and not isinstance(value, str):
        return False
    if expected == "array" and not isinstance(value, list):
        return False
    if "const" in rule and value != rule["const"]:
        return False
    if "pattern" in rule and not re.fullmatch(rule["pattern"], value):
        return False
    if isinstance(value, str) and len(value) < rule.get("minLength", 0):
        return False
    if "items" in rule and any(not validate_rule(item, rule["items"]) for item in value):
        return False
    if rule.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
        return False
    return True

good = {
    "schema_version": "release-evidence/v1",
    "service.version": "20260716-1430-a1b2c3d",
    "git_sha": "a" * 40,
    "image_digest": "sha256:" + "b" * 64,
    "config_repo_revision": "c" * 40,
    "work_items": ["PLAT-123", "PLAT-128"],
}
assert validate(good)
for patch in (
    {"service.version": "latest"},
    {"service.version": "Latest"},
    {"service.version": " "},
    {"service.version": 123},
    {"git_sha": "a1b2c3d"},
    {"image_digest": "sha256:short"},
    {"release_id": good["service.version"]},
    {"work_items": "PLAT-123"},
    {"work_items": ["PLAT-123", "PLAT-123"]},
):
    candidate = good | patch
    assert not validate(candidate), patch

print("release evidence contract: positive + 9 negative cases clean")
PY
