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

for token in tenant.id service.namespace gen_ai.prompt.name gen_ai.tool.call.id observability_conformance_command conformance-profile-v2.json; do
  grep -Fq "$token" "$SKILL"
  grep -Fq "$token" "$STANDARD"
done

python3 - "$PROFILE" "$EXT_PROFILE" <<'PY'
import json, sys
p=json.load(open(sys.argv[1]))
p["custom_attribute_allowlists"]={"example.agent.role":["primary","worker"],"example.workflow.phase":["execute","prepare"]}
p["consistent_trace_attributes"]=["example.agent.invocation.id"]
p["metric_label_forbidden_keys"]=["example.agent.invocation.id"]
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

for mutation in parent field role_enum role_length phase_enum invocation_missing invocation_mismatch metric_label tenant content_dev_flag bootstrap empty resource_tenant span_tenant legacy_exact legacy_prefix_span legacy_prefix_event placeholder stream_completed_status stream_incomplete_status async_missing async_restore async_parent async_trace producer_count producer_v1 producer_vendor vendor_path metadata_flatten malformed trace; do
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
echo "observability conformance: 2 positive profiles + 31 mutations clean"
