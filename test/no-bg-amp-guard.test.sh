#!/usr/bin/env bash
# no-bg-amp-guard.sh — PreToolUse(Bash) guard. Drives it with synthetic tool_input.command
# and asserts: deny ONLY a watcher invocation backgrounded with a trailing `&`/`& disown`;
# everything else (foreground watch, `&&` chains, non-watch `&`, dispatch, empty) passes.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/cto-orchestration/references/agent-watch/no-bg-amp-guard.sh"

echo "== no-bg-amp-guard.sh =="

if ! command -v jq >/dev/null 2>&1; then
  echo "    jq not on PATH — guard test skipped"; exit 0
fi

run() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -R .)" | bash "$GUARD"; }

# --- DENY: watcher backgrounded with shell & ---
out="$(run 'references/agent-watch/watch myproj-task-omp &')"
chk_contains "trailing & on watch denied" '"permissionDecision":"deny"' "$out"
out="$(run 'bash references/agent-watch/watch s1 & disown')"
chk_contains "& disown on watch denied" '"permissionDecision":"deny"' "$out"

# --- ALLOW (silent): not a shell-backgrounded watcher ---
out="$(run 'references/agent-watch/watch s1; rc=$?')"
chk_eq "foreground watch allowed" "" "$out"
out="$(run 'references/agent-watch/watch s1 && echo done')"
chk_eq "watch in && chain allowed" "" "$out"
out="$(run 'sleep 5 &')"
chk_eq "non-watch & allowed" "" "$out"
out="$(run 'references/agent-watch/dispatch omp s1 /wt')"
chk_eq "dispatch allowed" "" "$out"
out="$(run 'references/agent-watch/teardown s1')"
chk_eq "teardown allowed" "" "$out"

# --- ALLOW: degenerate stdin never blocks work ---
out="$(printf '{"tool_input":{}}' | bash "$GUARD")"; rc=$?
chk_eq "missing command allowed" "" "$out"; chk_eq "missing command exit 0" 0 "$rc"
out="$(printf '' | bash "$GUARD")"; rc=$?
chk_eq "empty stdin allowed" "" "$out"; chk_eq "empty stdin exit 0" 0 "$rc"

# deny payload is valid PreToolUse JSON
out="$(run 'references/agent-watch/watch s1 &')"
ev="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
chk_eq "deny is valid PreToolUse JSON" "PreToolUse" "$ev"

summary
