#!/usr/bin/env bash
# cto-guard-agent.py — non-Bash tool-call guard, THREE branches routed on (hook_event_name, tool_name):
#   P0a PreToolUse·Agent|Task   browser dispatch loading chrome-devtools MCP -> DENY (Playwright-first)
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

# ── P0a: browser dispatch that LOADS chrome-devtools MCP -> DENY; prose mention passes ──
run PreToolUse Agent '{"prompt":"browser E2E on localhost:3000; ToolSearch select:mcp__chrome-devtools__take_snapshot"}'
chk_eq "chrome-devtools tool token denied (exit 2)" 2 "$RC"
chk_contains "deny points to Playwright" "Playwright" "$ERR"
run PreToolUse Agent '{"prompt":"browser E2E via Playwright MCP; 绝不用 chrome-devtools 的工具"}'
chk_eq "prose mention (no mcp__ token) allowed" 0 "$RC"
# note: the token itself matches BROWSER_RE (substring chrome-devtools) → token anywhere = deny.
run PreToolUse Agent '{"prompt":"analyze mcp__chrome-devtools docs, no browser work"}'
chk_eq "token alone still denies (token implies browser-ish)" 2 "$RC"

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
out="$(printf '' | python3 "$GUARD")"; rc=$?
chk_eq "empty stdin exit 0" 0 "$rc"; chk_eq "empty stdin no output" "" "$out"

summary
