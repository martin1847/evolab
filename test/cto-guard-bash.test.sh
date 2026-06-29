#!/usr/bin/env bash
# cto-guard-bash.py — PreToolUse·Bash guard. Drives it with synthetic tool_input.command payloads.
# Asserts: (1) deny trailing `&`/`& disown` ; (2) deny naive idle==done poller (no positive grep) ;
# everything else passes silently. Deny = exit 2 + stderr ; pass = exit 0, no output.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

GUARD="../skills/cto-orchestration/references/agent-watch/cto-guard-bash.py"

echo "== cto-guard-bash.py =="

if ! command -v python3 >/dev/null 2>&1; then
  echo "    python3 not on PATH — guard test skipped"; exit 0
fi

mkcmd() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"; }
run() { # $1 command -> OUT(stdout) ERR(stderr) RC
  local tmpe; tmpe="$(mktemp)"
  OUT="$(mkcmd "$1" | python3 "$GUARD" 2>"$tmpe")"; RC=$?
  ERR="$(cat "$tmpe")"; rm -f "$tmpe"
}

# wired as executable via frontmatter `./...` — exec bit + shebang must hold
chk_eq "script is executable" 1 "$([ -x "$GUARD" ] && echo 1 || echo 0)"

# (1) trailing shell & -> ORPHAN, DENY
run 'npm run dev &'
chk_eq "trailing & denied (exit 2)" 2 "$RC"; chk_contains "trailing & stderr" "ORPHAN" "$ERR"
run 'bash watch s1 & disown'
chk_eq "& disown denied" 2 "$RC"
run 'nohup poll.sh &'
chk_eq "nohup ... & denied" 2 "$RC"
# ALLOW (silent): not a trailing-& backgrounding
run 'a && echo done'
chk_eq "&& chain allowed" 0 "$RC"; chk_eq "&& chain no stderr" "" "$ERR"
run 'curl -s url 2>&1 | tee log'
chk_eq "2>&1 redirect allowed" 0 "$RC"
run 'echo "a & b"'
chk_eq "& inside quotes allowed" 0 "$RC"
# embedded quotes/braces — the case shell-regex would choke on, python json parses
run 'echo "a & b }" && ls'
chk_eq "embedded quotes/braces allowed" 0 "$RC"

# (2) naive idle==done poller, DENY
run 'while true; do tmux capture-pane -p | grep Working; sleep 5; done'
chk_eq "naive idle poller denied (exit 2)" 2 "$RC"; chk_contains "idle poller stderr" "idle" "$ERR"
# ALLOW: poller WITH positive-evidence check
run 'while true; do tmux capture-pane -p|grep Working; git diff --stat; sleep 5; done'
chk_eq "poller + git positive allowed" 0 "$RC"
run 'for i in 1 2; do tmux capture-pane -p | grep -E "busy|Verdict"; done'
chk_eq "poller + Verdict positive allowed" 0 "$RC"
# ALLOW: capture-pane but no loop
run 'tmux capture-pane -p | grep Working'
chk_eq "single capture (no loop) allowed" 0 "$RC"

# degenerate: never block, exit 0
run ''
chk_eq "empty command allowed" 0 "$RC"; chk_eq "empty command no stderr" "" "$ERR"
out="$(printf '' | python3 "$GUARD")"; rc=$?
chk_eq "empty stdin exit 0" 0 "$rc"; chk_eq "empty stdin no output" "" "$out"

summary
