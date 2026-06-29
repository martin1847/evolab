#!/usr/bin/env bash
# cto-guard-agent.py — PostToolUse·Agent|Task guard. Drives it with synthetic tool_input.prompt.
# Asserts: browser/E2E subagent prompt -> reminder as JSON hookSpecificOutput.additionalContext
# (plain stdout would only reach the debug log, never the agent); non-browser prompt -> silent exit 0.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/cto-orchestration/references/agent-watch/cto-guard-agent.py"

echo "== cto-guard-agent.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — guard test skipped"; exit 0
fi

mkp() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"prompt":sys.argv[1]}}))' "$1"; }
run() { local tmpe; tmpe="$(mktemp)"; OUT="$(mkp "$1" | python3 "$GUARD" 2>"$tmpe")"; RC=$?; ERR="$(cat "$tmpe")"; rm -f "$tmpe"; }
ctx() { printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }

chk_eq "script is executable" 1 "$([ -x "$GUARD" ] && echo 1 || echo 0)"

# browser/E2E prompt -> JSON additionalContext reminder, exit 0
run 'run playwright E2E against localhost:3000'
chk_eq "browser prompt exit 0" 0 "$RC"
chk_eq "reminder hookEventName" "PostToolUse" "$(printf '%s' "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)"
chk_contains "reminder in additionalContext" "BLACK-HOLE" "$(ctx "$OUT")"
run 'take a screenshot of the dev server'
chk_contains "screenshot prompt reminded" "BLACK-HOLE" "$(ctx "$OUT")"

# non-browser prompt -> silent
run 'refactor the auth module and run unit tests'
chk_eq "non-browser no output" "" "$OUT"; chk_eq "non-browser exit 0" 0 "$RC"

# degenerate
out="$(printf '' | python3 "$GUARD")"; rc=$?
chk_eq "empty stdin exit 0" 0 "$rc"; chk_eq "empty stdin no output" "" "$out"

summary
