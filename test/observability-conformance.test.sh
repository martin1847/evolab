#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/obs-conformance.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ORACLE="$ROOT/skills/observability-standard/scripts/observability_conformance.py"
PROFILE="$ROOT/skills/observability-standard/references/conformance-profile-v2.json"
SKILL="$ROOT/skills/observability-standard/SKILL.md"
STANDARD="$ROOT/skills/observability-standard/references/standard.md"
EXT_PROFILE="$TMP/extended-profile.json"

for token in tenant.id service.namespace gen_ai.prompt.name gen_ai.tool.call.id observability_conformance_command conformance-profile-v2.json conformance-profile-v3.json; do
  grep -Fq "$token" "$SKILL"
  grep -Fq "$token" "$STANDARD"
done

python3 - "$PROFILE" "$EXT_PROFILE" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
p["custom_attribute_allowlists"]={"example.agent.role":["primary","worker"],"example.workflow.phase":["execute","prepare"]}
p["consistent_trace_attributes"]=["example.agent.invocation.id"]
p["metric_label_forbidden_keys"].append("example.agent.invocation.id")
p["forbidden_keys"].append("example.deprecated")
p["forbidden_key_prefixes"]=["example.legacy."]
json.dump(p, open(sys.argv[2], "w"))
PY

cat >"$TMP/good.json" <<'JSON'
{"resource":{"service.name":"svc","service.version":"tag","service.namespace":"product","deployment.environment.name":"development","k8s.namespace.name":"runtime"},"tenant":{"verified":false},"processes":[{"name":"api","instrumentation_bootstrapped":true},{"name":"worker","instrumentation_bootstrapped":true}],"gen_ai_enabled":true,"content_capture_allowed":false,"metric_label_keys":["example.agent.role","example.workflow.phase"],"static_guard":{"semantic_producers":["litellm_sdk_semconv"],"vendor_or_legacy_paths":[],"arbitrary_metadata_flatteners":[]},"tool_envelopes":[{"tool_call_id":"call-1"}],"spans":[{"trace_id":"trace","span_id":"domain","parent_span_id":null,"role":"domain","ended":true,"attributes":{"gen_ai.operation.name":"invoke_workflow","example.agent.role":"primary","example.agent.invocation.id":"inv-1","example.workflow.phase":"prepare"}},{"trace_id":"trace","span_id":"worker","parent_span_id":"domain","role":"invocation","ended":true,"async_boundary":"worker_callback","context_restored":true,"attributes":{"gen_ai.operation.name":"invoke_agent","example.agent.invocation.id":"inv-1"}},{"trace_id":"trace","span_id":"llm","parent_span_id":"worker","role":"inference","ended":true,"streaming":true,"stream_completed":true,"status":"success","attributes":{"gen_ai.operation.name":"chat","gen_ai.provider.name":"provider","gen_ai.request.model":"model","gen_ai.prompt.name":"prompt","gen_ai.prompt.version":"1","example.agent.invocation.id":"inv-1"}}]}
JSON
python3 "$ORACLE" "$TMP/good.json" --profile "$EXT_PROFILE" >/dev/null

cat >"$TMP/non-gen-ai.json" <<'JSON'
{"resource":{"service.name":"gateway","service.version":"tag"},"tenant":{"verified":false},"processes":[{"name":"api","instrumentation_bootstrapped":true}],"spans":[{"trace_id":"trace","span_id":"server","parent_span_id":null,"role":"server","ended":true,"attributes":{}}]}
JSON
python3 "$ORACLE" "$TMP/non-gen-ai.json" --profile "$PROFILE" >/dev/null

for mutation in version_numeric version_slash version_space version_placeholder; do
  python3 - "$TMP/non-gen-ai.json" "$TMP/non-gen-ai-$mutation.json" "$mutation" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); m=sys.argv[3]
if m=="version_numeric": p["resource"]["service.version"]=123
elif m=="version_slash": p["resource"]["service.version"]="team/tag"
elif m=="version_space": p["resource"]["service.version"]="bad tag"
else: p["resource"]["service.version"]="LaTeSt"
json.dump(p, open(sys.argv[2], "w"))
PY
  if python3 "$ORACLE" "$TMP/non-gen-ai-$mutation.json" --profile "$PROFILE" >"$TMP/non-gen-ai-$mutation.out"; then
    echo "non-GenAI service.version mutation unexpectedly passed: $mutation" >&2; exit 1
  fi
  if [ "$mutation" = version_numeric ]; then expected=resource.service_version_type
  elif [ "$mutation" = version_placeholder ]; then expected=resource.placeholder
  else expected=resource.service_version_shape
  fi
  grep -Fq "$expected" "$TMP/non-gen-ai-$mutation.out"
done

python3 - "$TMP/non-gen-ai.json" "$TMP/non-gen-ai-run-label.json" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); p["metric_label_keys"]=["run.id"]
json.dump(p, open(sys.argv[2], "w"))
PY
if python3 "$ORACLE" "$TMP/non-gen-ai-run-label.json" --profile "$PROFILE" >/dev/null; then
  echo "non-GenAI run.id metric label unexpectedly passed" >&2; exit 1
fi

for mutation in parent field role_enum role_length phase_enum invocation_missing invocation_mismatch metric_label tenant content_dev_flag bootstrap empty resource_tenant span_tenant legacy_exact legacy_prefix_span legacy_prefix_event placeholder version_numeric version_slash version_space stream_completed_status stream_incomplete_status async_missing async_restore async_parent async_trace producer_count producer_v1 producer_vendor vendor_path metadata_flatten malformed trace; do
  python3 - "$TMP/good.json" "$TMP/$mutation.json" "$mutation" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); m=sys.argv[3]
if m=="parent": p["spans"][2]["parent_span_id"]="missing"
elif m=="field": p["spans"][2]["attributes"]["gen_ai.operation.name"]="inference"
elif m=="role_enum": p["spans"][0]["attributes"]["example.agent.role"]="unknown"
elif m=="role_length": p["spans"][0]["attributes"]["example.agent.role"]="x"*33
elif m=="phase_enum": p["spans"][0]["attributes"]["example.workflow.phase"]="unknown"
elif m=="invocation_missing": p["spans"][1]["attributes"].pop("example.agent.invocation.id")
elif m=="invocation_mismatch": p["spans"][2]["attributes"]["example.agent.invocation.id"]="inv-2"
elif m=="metric_label": p["metric_label_keys"].append("example.agent.invocation.id")
elif m=="tenant": p["tenant"]={"verified":False,"id":"product"}
elif m=="content_dev_flag": p["content_capture_allowed"]=True; p["spans"][2]["attributes"]["gen_ai.input.messages"]="sentinel"
elif m=="bootstrap": p["processes"][1]["instrumentation_bootstrapped"]=False
elif m=="empty": p["spans"]=[]; p["processes"]=[]
elif m=="resource_tenant": p["resource"]["tenant.id"]="tenant-a"
elif m=="span_tenant": p["spans"][0]["attributes"]["tenant.id"]="tenant-a"
elif m=="legacy_exact": p["spans"][0]["attributes"]["example.deprecated"]="x"
elif m=="legacy_prefix_span": p["spans"][0]["attributes"]["example.legacy.unexpected"]="x"
elif m=="legacy_prefix_event": p["events"]=[{"attributes":{"example.legacy.actor":"primary"}}]
elif m=="placeholder": p["resource"]["service.version"]="latest"
elif m=="version_numeric": p["resource"]["service.version"]=123
elif m=="version_slash": p["resource"]["service.version"]="team/tag"
elif m=="version_space": p["resource"]["service.version"]="bad tag"
elif m=="stream_completed_status": p["spans"][2]["status"]="error"
elif m=="stream_incomplete_status": p["spans"][2]["stream_completed"]=False; p["spans"][2]["status"]="success"
elif m=="async_missing": p["spans"][1].pop("async_boundary")
elif m=="async_restore": p["spans"][1]["context_restored"]=False
elif m=="async_parent": p["spans"][1]["parent_span_id"]=None
elif m=="async_trace": p["spans"][1]["trace_id"]="other"
elif m=="producer_count": p["static_guard"]["semantic_producers"].append("custom_callback")
elif m=="producer_v1": p["static_guard"]["semantic_producers"]=["litellm_otel_v1"]
elif m=="producer_vendor": p["static_guard"]["semantic_producers"]=["langfuse_sdk"]
elif m=="vendor_path": p["static_guard"]["vendor_or_legacy_paths"].append("langfuse_sdk")
elif m=="metadata_flatten": p["static_guard"]["arbitrary_metadata_flatteners"].append("proxy_metadata")
elif m=="malformed": p["resource"]=[]
elif m=="trace": p["spans"][2]["trace_id"]="other"
json.dump(p, open(sys.argv[2],"w"))
PY
  if python3 "$ORACLE" "$TMP/$mutation.json" --profile "$EXT_PROFILE" >/dev/null; then
    echo "mutation unexpectedly passed: $mutation" >&2; exit 1
  fi
done
echo "observability conformance: 2 positive profiles + 39 mutations clean"

# ── v3: conditional content capture with executable redaction evidence ────────
# v2 above stays unconditional fail-closed (content_dev_flag mutation included).
# v3 is the explicit versioned channel: runtime flag + non-prod environment +
# a real redaction probe, with audit/persistent evidence still hash-only.
V3_PROFILE="$ROOT/skills/observability-standard/references/conformance-profile-v3.json"
EXT_V3="$TMP/extended-profile-v3.json"

# v3 must carry every v2 rule byte-identically; a dropped rule is a silent loosening.
python3 - "$PROFILE" "$V3_PROFILE" "$EXT_V3" <<'PY'
import json, sys
v2 = json.load(open(sys.argv[1]))
v3 = json.load(open(sys.argv[2]))
assert v3["schema_version"] == "observability-conformance/v3", v3["schema_version"]
for key, value in v2.items():
    if key == "schema_version":
        continue
    assert key in v3, f"v3 dropped v2 rule: {key}"
    assert v3[key] == value, f"v3 changed v2 rule: {key}"
cfg = v3["content_capture"]
for key in ("flag_field", "environment_resource_key", "allowed_environment_pattern", "redaction_probe", "audit_sink"):
    assert key in cfg, f"v3 content_capture missing {key}"
for key in ("field", "canary_field", "canary_class_field", "canary_value_field", "output_field", "required_canary_classes", "min_output_chars", "forbidden_output_patterns"):
    assert key in cfg["redaction_probe"], f"v3 redaction_probe missing {key}"
for key in ("field", "hash_value_pattern", "metadata_key_allowlist", "metadata_max_length"):
    assert key in cfg["audit_sink"], f"v3 audit_sink missing {key}"
for canary_class in cfg["redaction_probe"]["required_canary_classes"]:
    assert canary_class in cfg["redaction_probe"]["forbidden_output_patterns"], canary_class
# same organisation extension as the v2 run, so v3 inherits identical custom-field coverage
v3["custom_attribute_allowlists"] = {"example.agent.role": ["primary", "worker"], "example.workflow.phase": ["execute", "prepare"]}
v3["consistent_trace_attributes"] = ["example.agent.invocation.id"]
v3["metric_label_forbidden_keys"].append("example.agent.invocation.id")
v3["forbidden_keys"].append("example.deprecated")
v3["forbidden_key_prefixes"] = ["example.legacy."]
json.dump(v3, open(sys.argv[3], "w"))
PY

# Key-shaped canary, `ak-` family: still matched by the profile's api_key pattern, and
# not a credential shape the repo's pre-commit redaction gate must keep blocking.
CANARY_KEY="ak-canary0011223344"
CANARY_MAIL="canary.user@example.invalid"
python3 - "$TMP/good.json" "$TMP/v3-good.json" "$CANARY_KEY" "$CANARY_MAIL" <<'PY'
import hashlib, json, sys
p = json.load(open(sys.argv[1]))
sample = '[{"role":"user","content":"debug sample"}]'
p["content_capture_allowed"] = True
p["spans"][2]["attributes"]["gen_ai.input.messages"] = sample
p["redaction_probe"] = {
    "canaries": [{"class": "api_key", "value": sys.argv[3]}, {"class": "email", "value": sys.argv[4]}],
    "redacted": ["key=[REDACTED:api_key]", "to=[REDACTED:email]"],
}
p["audit_records"] = [{
    "sink": "audit_log",
    "attributes": {"gen_ai.input.messages": "sha256:" + hashlib.sha256(sample.encode()).hexdigest()},
}]
json.dump(p, open(sys.argv[2], "w"))
PY

v3_verdict() { # label snapshot [expected-error-code; empty = expect green]
  local label="$1" snap="$2" expected="${3:-}" out rc
  out="$TMP/v3-verdict-$label.out"
  if python3 "$ORACLE" "$snap" --profile "$EXT_V3" >"$out"; then rc=0; else rc=1; fi
  if [ -z "$expected" ]; then
    [ "$rc" -eq 0 ] || { echo "v3 $label: expected GREEN, oracle failed: $(cat "$out")" >&2; exit 1; }
    echo "v3 $label: GREEN (oracle ok=true)"
  else
    [ "$rc" -ne 0 ] || { echo "v3 $label: expected RED, oracle passed" >&2; exit 1; }
    grep -Fq "$expected" "$out" || { echo "v3 $label: RED but not on $expected: $(cat "$out")" >&2; exit 1; }
    echo "v3 $label: RED $expected"
  fi
}

# contract point ④ prerequisite: the very same snapshot must stay red on v2.
if python3 "$ORACLE" "$TMP/v3-good.json" --profile "$EXT_PROFILE" >"$TMP/v3-good-under-v2.out"; then
  echo "v2 profile unexpectedly allowed content capture" >&2; exit 1
fi
grep -Fq "content.leak" "$TMP/v3-good-under-v2.out"
echo "v3 positive snapshot under v2 profile: RED content.leak (v2 stays fail-closed)"

# Dispatch is by declared schema_version, not by section presence: a v2 profile with the
# section injected, an incomplete v3 section, an unknown version and a required canary
# class without a shape are all invalid profiles, and an invalid profile decides nothing.
v3_profile_verdict() { # label profile expected-error-code
  local label="$1" prof="$2" expected="$3" out
  out="$TMP/v3-profile-$label.out"
  if python3 "$ORACLE" "$TMP/v3-good.json" --profile "$prof" >"$out"; then
    echo "v3 profile $label: expected RED, oracle passed" >&2; exit 1
  fi
  grep -Fq "$expected" "$out" || { echo "v3 profile $label: RED but not on $expected: $(cat "$out")" >&2; exit 1; }
  echo "v3 profile $label: RED $expected"
}

for pmutation in v2_with_content_capture v3_incomplete_section unknown_version class_without_pattern; do
  python3 - "$EXT_PROFILE" "$EXT_V3" "$TMP/v3-profile-$pmutation.json" "$pmutation" <<'PY'
import json, sys
v2 = json.load(open(sys.argv[1]))
v3 = json.load(open(sys.argv[2]))
m = sys.argv[4]
if m == "v2_with_content_capture":
    v2["content_capture"] = v3["content_capture"]
    out = v2
elif m == "v3_incomplete_section":
    v3["content_capture"]["audit_sink"].pop("metadata_key_allowlist")
    out = v3
elif m == "unknown_version":
    v3["schema_version"] = "observability-conformance/v4"
    out = v3
elif m == "class_without_pattern":
    v3["content_capture"]["redaction_probe"]["required_canary_classes"].append("session_cookie")
    out = v3
else:
    raise SystemExit(f"unknown v3 profile mutation: {m}")
json.dump(out, open(sys.argv[3], "w"))
PY
  case "$pmutation" in
    v2_with_content_capture) pexpected=profile.content_capture_unexpected ;;
    v3_incomplete_section) pexpected=profile.content_capture_incomplete ;;
    unknown_version) pexpected=profile.schema_version_unknown ;;
    class_without_pattern) pexpected=profile.canary_class_without_pattern ;;
    *) echo "v3 profile mutation without an expected error code: $pmutation" >&2; exit 1 ;;
  esac
  v3_profile_verdict "$pmutation" "$TMP/v3-profile-$pmutation.json" "$pexpected"
done

# an invalid profile must report only that, never a snapshot verdict computed under it
python3 - "$TMP/v3-profile-v2_with_content_capture.out" <<'PY'
import json, sys
errors = json.load(open(sys.argv[1]))["errors"]
assert errors == ["profile.content_capture_unexpected: observability-conformance/v2"], errors
PY

for mutation in env_prod_short env_alias_live env_alias_prd env_prod_padded env_allowed_uppercase env_missing probe_missing probe_pattern_leak probe_output_empty probe_output_absent probe_class_missing canary_shapeless capture_canary_leak audit_raw_value audit_alias_raw audit_array_raw audit_nested_array_raw audit_metadata_too_long contract1_flag_off contract2_prod_env contract3_probe_canary_leak; do
  python3 - "$TMP/v3-good.json" "$TMP/v3-$mutation.json" "$mutation" "$CANARY_KEY" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); m = sys.argv[3]; canary = sys.argv[4]
if m == "contract1_flag_off": p["content_capture_allowed"] = False
elif m == "contract2_prod_env": p["resource"]["deployment.environment.name"] = "production"
elif m == "contract3_probe_canary_leak": p["redaction_probe"]["redacted"][0] = f"key={canary}"
elif m == "env_prod_short": p["resource"]["deployment.environment.name"] = "prod"
elif m == "env_missing": p["resource"].pop("deployment.environment.name")
elif m == "probe_missing": p.pop("redaction_probe")
elif m == "probe_pattern_leak": p["redaction_probe"]["redacted"][1] = "to=alice@corp.example"
elif m == "probe_output_empty": p["redaction_probe"]["redacted"] = ["", "   "]
elif m == "probe_output_absent": p["redaction_probe"]["redacted"] = []
elif m == "probe_class_missing":
    p["redaction_probe"]["canaries"] = p["redaction_probe"]["canaries"][:1]
    p["redaction_probe"]["redacted"] = p["redaction_probe"]["redacted"][:1]
elif m == "audit_raw_value": p["audit_records"][0]["attributes"]["gen_ai.input.messages"] = "user: debug sample in the clear"
elif m == "env_alias_live": p["resource"]["deployment.environment.name"] = "live"
elif m == "env_alias_prd": p["resource"]["deployment.environment.name"] = "prd"
elif m == "env_prod_padded": p["resource"]["deployment.environment.name"] = "prod "
elif m == "env_allowed_uppercase": p["resource"]["deployment.environment.name"] = "Development"
elif m == "canary_shapeless":
    p["redaction_probe"]["canaries"] = [{"class": "api_key", "value": "x"}, {"class": "email", "value": "y"}]
elif m == "capture_canary_leak":
    p["spans"][2]["attributes"]["gen_ai.input.messages"] = '[{"role":"user","content":"debug sample %s"}]' % canary
elif m == "audit_alias_raw": p["audit_records"][0]["attributes"]["prompt_text"] = "user: debug sample in the clear"
elif m == "audit_array_raw": p["audit_records"] = ["cleartext-secret sample"]
elif m == "audit_nested_array_raw": p["audit_records"][0]["attributes"]["batch"] = [["user: nested cleartext"]]
elif m == "audit_metadata_too_long": p["audit_records"][0]["sink"] = "audit_log_" + "x" * 96
else: raise SystemExit(f"unknown v3 mutation: {m}")
json.dump(p, open(sys.argv[2], "w"))
PY
  case "$mutation" in
    contract1_flag_off) expected=content.capture_not_enabled ;;
    contract2_prod_env|env_prod_short|env_alias_live|env_alias_prd|env_prod_padded) expected=content.capture_forbidden_environment ;;
    env_allowed_uppercase) expected="" ;;
    env_missing) expected=content.capture_environment_unknown ;;
    probe_missing) expected=content.redaction_evidence_missing ;;
    contract3_probe_canary_leak) expected=content.redaction_canary_leak ;;
    probe_pattern_leak) expected=content.redaction_pattern_leak ;;
    probe_output_empty) expected=content.redaction_output_empty ;;
    probe_output_absent) expected=content.redaction_output_arity ;;
    probe_class_missing) expected=content.redaction_canary_class_missing ;;
    canary_shapeless) expected=content.redaction_canary_shape ;;
    capture_canary_leak) expected=content.capture_canary_leak ;;
    audit_raw_value|audit_alias_raw|audit_array_raw|audit_nested_array_raw) expected=content.audit_not_hashed ;;
    audit_metadata_too_long) expected=content.audit_metadata_too_long ;;
    *) echo "v3 mutation without an expected error code: $mutation" >&2; exit 1 ;;
  esac
  v3_verdict "$mutation" "$TMP/v3-$mutation.json" "$expected"
done

v3_verdict contract4_dev_flag_probe "$TMP/v3-good.json"
echo "observability conformance v3: 2 positive (dev+flag+probe, uppercase env) + 20 red mutations + 4 profile-identity reds clean; v2 unconditional fail-closed intact"
