#!/usr/bin/env bash
# cto-guard.py — single consolidated enforcement hook, dispatched on hook_event_name + tool_name.
# Drives it with synthetic hook payloads and asserts the three branches:
#   PreToolUse·Bash  (1) deny trailing `&`/`& disown`  (2) deny naive idle==done poller (no positive grep)
#   PostToolUse·Agent|Task  remind to set a deadline-watch for browser/E2E subagents
# Deny = exit 2 + stderr ; reminder = JSON hookSpecificOutput.additionalContext + exit 0 ; else passes exit 0.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/cto-orchestration/references/agent-watch/cto-guard.py"

echo "== cto-guard.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — guard test skipped"; exit 0
fi

mkjson() { # $1 event  $2 tool  $3 command-or-prompt
  python3 -c 'import json,sys
ev,tool,val=sys.argv[1],sys.argv[2],sys.argv[3]
ti={"command":val} if tool in ("Bash",) else {"prompt":val}
print(json.dumps({"hook_event_name":ev,"tool_name":tool,"tool_input":ti}))' "$1" "$2" "$3"
}

run() { # $1 event  $2 tool  $3 val  -> sets OUT(stdout) ERR(stderr) RC
  local tmpe; tmpe="$(mktemp)"
  OUT="$(mkjson "$1" "$2" "$3" | python3 "$GUARD" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}

# --- PreToolUse·Bash (1): trailing shell & -> ORPHAN, DENY (exit 2 + stderr) ---
run PreToolUse Bash 'npm run dev &'
chk_eq "trailing & denied (exit 2)" 2 "$RC"; chk_contains "trailing & stderr" "ORPHAN" "$ERR"
run PreToolUse Bash 'bash watch s1 & disown'
chk_eq "& disown denied" 2 "$RC"
run PreToolUse Bash 'nohup poll.sh &'
chk_eq "nohup ... & denied" 2 "$RC"

# ALLOW (silent, exit 0): not a trailing-& backgrounding
run PreToolUse Bash 'a && echo done'
chk_eq "&& chain allowed (exit 0)" 0 "$RC"; chk_eq "&& chain no stderr" "" "$ERR"
run PreToolUse Bash 'curl -s url 2>&1 | tee log'
chk_eq "2>&1 redirect allowed" 0 "$RC"
run PreToolUse Bash 'echo "a & b"'
chk_eq "& inside quotes allowed" 0 "$RC"

# --- PreToolUse·Bash (2): naive idle==done poller, DENY ---
run PreToolUse Bash 'while true; do tmux capture-pane -p | grep Working; sleep 5; done'
chk_eq "naive idle poller denied (exit 2)" 2 "$RC"; chk_contains "idle poller stderr" "idle" "$ERR"
# ALLOW: poller WITH positive-evidence check (git deliverable)
run PreToolUse Bash 'while true; do tmux capture-pane -p|grep Working; git diff --stat; sleep 5; done'
chk_eq "poller + git positive allowed" 0 "$RC"
# ALLOW: poller WITH pane Verdict grep (review path)
run PreToolUse Bash 'for i in 1 2; do tmux capture-pane -p | grep -E "busy|Verdict"; done'
chk_eq "poller + Verdict positive allowed" 0 "$RC"
# ALLOW: ordinary bash with capture-pane but no loop
run PreToolUse Bash 'tmux capture-pane -p | grep Working'
chk_eq "single capture (no loop) allowed" 0 "$RC"

# --- PostToolUse·Agent|Task: browser/E2E subagent -> REMIND via JSON additionalContext, exit 0 ---
# (plain-text stdout would only reach the debug log, never the agent — so assert the JSON contract)
ctx() { printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }
run PostToolUse Agent 'run playwright E2E against localhost:3000'
chk_eq "browser Agent exit 0" 0 "$RC"
chk_eq "browser reminder hookEventName" "PostToolUse" "$(printf '%s' "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)"
chk_contains "browser reminder in additionalContext" "BLACK-HOLE" "$(ctx "$OUT")"
run PostToolUse Task 'take a screenshot of the dev server'
chk_contains "browser Task reminded (additionalContext)" "BLACK-HOLE" "$(ctx "$OUT")"
# no reminder for non-browser subagent
run PostToolUse Agent 'refactor the auth module and run unit tests'
chk_eq "non-browser Agent no reminder" "" "$OUT"; chk_eq "non-browser Agent exit 0" 0 "$RC"

# --- degenerate / non-matching: never block, exit 0 ---
run PreToolUse Bash ''
chk_eq "empty command allowed" 0 "$RC"; chk_eq "empty command no stderr" "" "$ERR"
out="$(printf '' | python3 "$GUARD")"; rc=$?
chk_eq "empty stdin exit 0" 0 "$rc"; chk_eq "empty stdin no output" "" "$out"
run PreToolUse Read 'some-file'
chk_eq "non-Bash PreToolUse passes" 0 "$RC"
run PostToolUse Bash 'ls'
chk_eq "PostToolUse Bash (no branch) passes" 0 "$RC"

summary
