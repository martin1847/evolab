#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/obs-conformance.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ORACLE="$ROOT/skills/observability-standard/scripts/observability_conformance.py"
PROFILE="$ROOT/skills/observability-standard/references/conformance-profile-v2.json"
SKILL="$ROOT/skills/observability-standard/SKILL.md"
STANDARD="$ROOT/skills/observability-standard/references/standard.md"

for token in tenant.id service.namespace gen_ai.prompt.name gen_ai.tool.call.id observability_conformance_command conformance-profile-v2.json; do
  grep -Fq "$token" "$SKILL"
  grep -Fq "$token" "$STANDARD"
done

cat >"$TMP/good.json" <<'JSON'
{"resource":{"service.name":"svc","service.version":"tag","service.namespace":"product","deployment.environment.name":"development","k8s.namespace.name":"runtime"},"tenant":{"verified":false},"processes":[{"name":"api","instrumentation_bootstrapped":true},{"name":"worker","instrumentation_bootstrapped":true}],"gen_ai_enabled":true,"content_capture_allowed":false,"tool_envelopes":[{"tool_call_id":"call-1"}],"spans":[{"trace_id":"trace","span_id":"domain","parent_span_id":null,"role":"domain","ended":true,"attributes":{"gen_ai.operation.name":"invoke_workflow"}},{"trace_id":"trace","span_id":"llm","parent_span_id":"domain","role":"inference","ended":true,"streaming":true,"stream_completed":true,"status":"success","attributes":{"gen_ai.operation.name":"chat","gen_ai.provider.name":"provider","gen_ai.request.model":"model","gen_ai.prompt.name":"prompt","gen_ai.prompt.version":"1"}}]}
JSON
python3 "$ORACLE" "$TMP/good.json" --profile "$PROFILE" >/dev/null

cat >"$TMP/non-gen-ai.json" <<'JSON'
{"resource":{"service.name":"gateway","service.version":"tag"},"tenant":{"verified":false},"processes":[{"name":"api","instrumentation_bootstrapped":true}],"spans":[{"trace_id":"trace","span_id":"server","parent_span_id":null,"role":"server","ended":true,"attributes":{}}]}
JSON
python3 "$ORACLE" "$TMP/non-gen-ai.json" --profile "$PROFILE" >/dev/null

for mutation in parent field tenant content bootstrap empty resource_tenant span_tenant content_prod content_unknown placeholder stream_terminal malformed trace; do
  python3 - "$TMP/good.json" "$TMP/$mutation.json" "$mutation" <<'PY'
import json, sys
p=json.load(open(sys.argv[1])); m=sys.argv[3]
if m=="parent": p["spans"][1]["parent_span_id"]="missing"
elif m=="field": p["spans"][1]["attributes"]["gen_ai.operation.name"]="inference"
elif m=="tenant": p["tenant"]={"verified":False,"id":"product"}
elif m=="content": p["spans"][1]["attributes"]["gen_ai.input.messages"]="sentinel"
elif m=="bootstrap": p["processes"][1]["instrumentation_bootstrapped"]=False
elif m=="empty": p["spans"]=[]; p["processes"]=[]
elif m=="resource_tenant": p["resource"]["tenant.id"]="tenant-a"
elif m=="span_tenant": p["spans"][0]["attributes"]["tenant.id"]="tenant-a"
elif m=="content_prod": p["content_capture_allowed"]=True; p["resource"]["deployment.environment.name"]="production"; p["spans"][1]["attributes"]["gen_ai.input.messages"]="sentinel"
elif m=="content_unknown": p["content_capture_allowed"]=True; p["resource"].pop("deployment.environment.name"); p["spans"][1]["attributes"]["gen_ai.input.messages"]="sentinel"
elif m=="placeholder": p["resource"]["service.version"]="latest"
elif m=="stream_terminal": p["spans"][1]["stream_completed"]=False; p["spans"][1]["status"]="unknown"
elif m=="malformed": p["resource"]=[]
elif m=="trace": p["spans"][1]["trace_id"]="other"
json.dump(p, open(sys.argv[2],"w"))
PY
  if python3 "$ORACLE" "$TMP/$mutation.json" --profile "$PROFILE" >/dev/null; then
    echo "mutation unexpectedly passed: $mutation" >&2; exit 1
  fi
done
echo "observability conformance: 2 positive profiles + 14 mutations clean"
