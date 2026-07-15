#!/usr/bin/env bash
# cto-guard-agent.py — non-Bash tool-call guard, FOUR branches routed on (hook_event_name, tool_name):
#   P0a PreToolUse·Agent|Task   browser dispatch loading chrome-devtools MCP -> DENY (Playwright-first)
#   P0c PreToolUse·Agent|Task   dispatch missing explicit `model` -> DENY unless subagent_type "fork"
#   P0b PreToolUse·TaskStop     killing an ALIVE agent (fresh .output) -> DENY unless override marker
#   PostToolUse·Agent|Task      browser dispatch -> black-hole deadline reminder (JSON additionalContext)
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/cto-orchestration/references/agent-watch/cto-guard-agent.py"

echo "== cto-guard-agent.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — guard test skipped"; exit 0
fi

mkp() { # $1 event  $2 tool  $3 json-fragment-for-tool_input
  python3 -c 'import json,sys
print(json.dumps({"hook_event_name":sys.argv[1],"tool_name":sys.argv[2],"tool_input":json.loads(sys.argv[3])}))' "$1" "$2" "$3"
}
run() { local tmpe; tmpe="$(mktemp)"; OUT="$(mkp "$1" "$2" "$3" | python3 "$GUARD" 2>"$tmpe")"; RC=$?; ERR="$(cat "$tmpe")"; rm -f "$tmpe"; }
ctx() { printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }

chk_eq "script is executable" 1 "$([ -x "$GUARD" ] && echo 1 || echo 0)"

# ── PostToolUse reminder (JSON additionalContext; plain stdout would hit only the debug log) ──
run PostToolUse Agent '{"prompt":"run playwright E2E against localhost:3000"}'
chk_eq "browser prompt exit 0" 0 "$RC"
chk_eq "reminder hookEventName" "PostToolUse" "$(printf '%s' "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)"
chk_contains "reminder in additionalContext" "BLACK-HOLE" "$(ctx "$OUT")"
run PostToolUse Task '{"prompt":"take a screenshot of the dev server"}'
chk_contains "browser Task reminded" "BLACK-HOLE" "$(ctx "$OUT")"
run PostToolUse Agent '{"prompt":"refactor the auth module and run unit tests"}'
chk_eq "non-browser no reminder" "" "$OUT"; chk_eq "non-browser exit 0" 0 "$RC"
run PostToolUse Agent 'null'
chk_eq "PostToolUse malformed tool_input soft-abstains" 0 "$RC"; chk_eq "PostToolUse malformed tool_input silent" "" "$OUT$ERR"
run PostToolUse Task '{}'
chk_eq "PostToolUse missing prompt soft-abstains" 0 "$RC"; chk_eq "PostToolUse missing prompt silent" "" "$OUT$ERR"
run PostToolUse Agent '{"prompt":42}'
chk_eq "PostToolUse wrong prompt type soft-abstains" 0 "$RC"; chk_eq "PostToolUse wrong prompt type silent" "" "$OUT$ERR"
tmpe="$(mktemp)"; out="$(python3 -c 'import io,json,runpy,sys; sys.stdin=io.StringIO("{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"run browser E2E\"}}"); original=json.dumps; json.dumps=lambda *a,**k: (_ for _ in ()).throw(RuntimeError("boom")); runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "PostToolUse internal failure soft-abstains" 0 "$rc"; chk_eq "PostToolUse internal failure silent" "" "$out$err"

# ── P0a: browser dispatch that LOADS chrome-devtools MCP -> DENY; prose mention passes ──
run PreToolUse Agent '{"prompt":"browser E2E on localhost:3000; ToolSearch select:mcp__chrome-devtools__take_snapshot"}'
chk_eq "chrome-devtools tool token denied (exit 2)" 2 "$RC"
chk_contains "deny points to Playwright" "Playwright" "$ERR"
run PreToolUse Agent '{"prompt":"browser E2E via Playwright MCP; 绝不用 chrome-devtools 的工具","model":"sonnet"}'
chk_eq "prose mention (no mcp__ token) allowed" 0 "$RC"
# note: the token itself matches BROWSER_RE (substring chrome-devtools) → token anywhere = deny.
run PreToolUse Agent '{"prompt":"analyze mcp__chrome-devtools docs, no browser work"}'
chk_eq "token alone still denies (token implies browser-ish)" 2 "$RC"

# ── P0c: Agent/Task dispatch missing explicit `model` -> DENY unless subagent_type "fork" ──
run PreToolUse Agent '{"prompt":"run the test suite"}'
chk_eq "Agent no model denied (exit 2)" 2 "$RC"
chk_contains "deny mentions model tiers" "economy tier" "$ERR"
run PreToolUse Agent '{"prompt":"run the test suite","model":"sonnet"}'
chk_eq "Agent with model allowed" 0 "$RC"
run PreToolUse Agent '{"prompt":"adversarial review of the PR","model":"gpt-5.6"}'
chk_eq "non-Claude model name allowed (no allowlist)" 0 "$RC"
run PreToolUse Agent '{"prompt":"continue prior context","subagent_type":"fork"}'
chk_eq "fork subagent exempt from model requirement" 0 "$RC"
run PreToolUse Task '{"prompt":"run the test suite"}'
chk_eq "Task no model denied (exit 2)" 2 "$RC"
run PreToolUse Read '{"file_path":"/tmp/x"}'
chk_eq "non-Agent/Task tool unaffected by model requirement" 0 "$RC"

# ── P0d: e2e-runner dispatch (brief carries E2E_ECONOMY=1) must ride an economy tier ──
run PreToolUse Agent '{"prompt":"run: E2E_ECONOMY=1 bash test/e2e/run.sh and report","model":"opus"}'
chk_eq "e2e runner on opus denied (exit 2)" 2 "$RC"
chk_contains "e2e-runner deny names economy tier" "economy tier" "$ERR"
chk_contains "e2e-runner deny carries doc pointer" "SKILL.md" "$ERR"
run PreToolUse Agent '{"prompt":"run: E2E_ECONOMY=1 bash test/e2e/run.sh and report","model":"fable"}'
chk_eq "e2e runner on fable denied" 2 "$RC"
run PreToolUse Agent '{"prompt":"run: E2E_ECONOMY=1 bash test/e2e/run.sh and report","model":"haiku"}'
chk_eq "e2e runner on haiku allowed" 0 "$RC"
run PreToolUse Agent '{"prompt":"adversarial review of test/e2e/onboard.e2e.sh changes","model":"opus"}'
chk_eq "premium review of e2e code (no marker) allowed" 0 "$RC"

# ── P0b: TaskStop on an ALIVE agent (fresh transcript) -> DENY; stale or overridden -> allow ──
TID="zzguardtest$$"
FAKE="/tmp/claude-zztest/a/b/tasks"; mkdir -p "$FAKE"
touch "$FAKE/$TID.output"                                   # fresh = alive
run PreToolUse TaskStop "{\"task_id\":\"$TID\"}"
chk_eq "kill fresh agent denied (exit 2)" 2 "$RC"; chk_contains "deny says ALIVE" "ALIVE" "$ERR"
touch "/tmp/cto-allow-kill-$TID"                            # explicit override
run PreToolUse TaskStop "{\"task_id\":\"$TID\"}"
chk_eq "override marker allows kill" 0 "$RC"
rm -f "/tmp/cto-allow-kill-$TID"
touch -t 202601010000 "$FAKE/$TID.output"                   # stale = not alive
run PreToolUse TaskStop "{\"task_id\":\"$TID\"}"
chk_eq "stale transcript allows kill" 0 "$RC"
run PreToolUse TaskStop '{"task_id":"zz-ghost-task-000"}'
chk_eq "unknown task allows (no transcript found)" 0 "$RC"
rm -rf /tmp/claude-zztest

# ── degenerate ──
tmpe="$(mktemp)"; out="$(printf 'not json' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "malformed JSON is checker error" 2 "$rc"; chk_contains "malformed JSON marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"model":"sonnet"}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "matching Agent missing prompt is checker error" 2 "$rc"; chk_contains "missing prompt marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"TaskStop","tool_input":{"task_id":42}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "matching TaskStop wrong id type is checker error" 2 "$rc"; chk_contains "wrong id type marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":null}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "non-applicable tool stays allowed" 0 "$rc"; chk_eq "non-applicable tool silent" "" "$err"
tmpe="$(mktemp)"; out="$(python3 -c 'import glob,io,runpy,sys; sys.stdin=io.StringIO("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"TaskStop\",\"tool_input\":{\"task_id\":\"broken-checker\"}}"); glob.glob=lambda *a,**k: (_ for _ in ()).throw(RuntimeError("boom")); runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "internal Agent checker failure exits 2" 2 "$rc"; chk_contains "internal Agent checker failure marker" "CHECKER-ERROR" "$err"

summary
