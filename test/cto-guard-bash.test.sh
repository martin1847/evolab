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

mkcmd() { # $1 command, $2 run_in_background (optional "1")
  python3 -c 'import json,sys
ti={"command":sys.argv[1]}
if len(sys.argv)>2 and sys.argv[2]=="1": ti["run_in_background"]=True
print(json.dumps({"tool_input":ti}))' "$@"; }
run() { # $1 command [$2 run_in_background] -> OUT(stdout) ERR(stderr) RC
  local tmpe; tmpe="$(mktemp)"
  OUT="$(mkcmd "$@" | python3 "$GUARD" 2>"$tmpe")"; RC=$?
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
# `&& disown` is a (nonsensical) && chain, not a trailing-& backgrounding -> allowed (one-regex simplification)
run 'a && disown'
chk_eq "&& disown allowed (not a bg &)" 0 "$RC"
# mid-chain backgrounding `foo & bar` (background-then-chain) — the 2026-07-04 blind spot, now DENY
run 'nohup poll.sh & echo started'
chk_eq "background-then-chain denied" 2 "$RC"

# (4) raw tmux send-keys with CJK / long payload -> DENY (popup eats Enter); safe path passes
run 'tmux send-keys -t s1 "请把理解门复述发我，确认后开工①②③" Enter'
chk_eq "send-keys CJK denied (exit 2)" 2 "$RC"; chk_contains "send-keys deny points to dispatch send" "dispatch send" "$ERR"
run 'tmux send-keys -t s1 Escape'
chk_eq "send-keys control key allowed" 0 "$RC"
run 'tmux send-keys -t s1 "read /tmp/goal.md" Enter'
chk_eq "send-keys short ASCII allowed" 0 "$RC"
run 'bash references/agent-watch/dispatch send s1 -m "长中文放行指令：按评审意见回修①②"'
chk_eq "dispatch send safe path allowed" 0 "$RC"

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

# (3) dispatch WITHOUT a later `watch <session>` -> ALLOW + JSON additionalContext reminder (omission)
ctx() { printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }
run 'bash references/agent-watch/dispatch omp mysess /wt'
chk_eq "dispatch w/o watch exit 0" 0 "$RC"
chk_contains "dispatch w/o watch reminds arm watcher" "watcher" "$(ctx "$OUT")"
chk_contains "reminder names the session" "mysess" "$(ctx "$OUT")"
# dispatch WITH watch on the same session, BACKGROUNDED -> silent (no double-nag)
run 'dispatch omp mysess /wt && bash references/agent-watch/watch mysess' 1
chk_eq "dispatch + watch same cmd (bg) exit 0" 0 "$RC"; chk_eq "dispatch + watch silent" "" "$OUT"
# fused `dispatch … --goal g` BACKGROUNDED auto-arms the watch in-process -> no reminder either
run 'bash references/agent-watch/dispatch omp mysess /wt --goal /tmp/g.md' 1
chk_eq "fused --goal (bg) exit 0" 0 "$RC"; chk_eq "fused --goal silent (auto watch)" "" "$OUT"

# (5) blocking watch / fused dispatch in the FOREGROUND -> DENY (killed at Bash timeout, exit 143)
run 'bash references/agent-watch/dispatch omp mysess /wt --goal /tmp/g.md'
chk_eq "fused --goal foreground denied" 2 "$RC"; chk_contains "foreground deny names 143" "143" "$ERR"
run 'dispatch send mysess -f /tmp/fix.md && bash references/agent-watch/watch mysess'
chk_eq "chained foreground watch denied (LH field case)" 2 "$RC"
run 'AGENT_WATCH_DELIVERABLE=/tmp/out/*.md bash references/agent-watch/watch mysess'
chk_eq "env-prefixed foreground watch denied" 2 "$RC"
# explicit sync opt-out for shell orchestrators that run watch synchronously by design
run 'AGENT_WATCH_SYNC=1 bash references/agent-watch/watch mysess; rc=$?'
chk_eq "AGENT_WATCH_SYNC=1 foreground allowed" 0 "$RC"
# exec-lane launch returns immediately -> foreground fine (inline prefix AND global env)
run 'DISPATCH_EXEC=1 bash references/agent-watch/dispatch omp mysess /wt --goal /tmp/g.md'
chk_eq "DISPATCH_EXEC=1 foreground launch allowed" 0 "$RC"
OUT="$(mkcmd 'bash references/agent-watch/dispatch omp mysess /wt --goal /tmp/g.md' | DISPATCH_EXEC=1 python3 "$GUARD" 2>/dev/null)"; RC=$?
chk_eq "global DISPATCH_EXEC env also allows foreground" 0 "$RC"
# path as an ARGUMENT is not an invocation (self-inflicted false positives, 2026-07-11)
run 'grep -n foo references/agent-watch/watch references/agent-watch/dispatch'
chk_eq "watch path as grep arg allowed" 0 "$RC"
run 'grep -n x agent-watch/emit.sh agent-watch/watch'
chk_eq "arg after .sh arg allowed (sh-suffix trap)" 0 "$RC"
# non-dispatch command -> silent
run 'git status'
chk_eq "non-dispatch silent" "" "$OUT"

# degenerate: never block, exit 0
run ''
chk_eq "empty command allowed" 0 "$RC"; chk_eq "empty command no stderr" "" "$ERR"
out="$(printf '' | python3 "$GUARD")"; rc=$?
chk_eq "empty stdin exit 0" 0 "$rc"; chk_eq "empty stdin no output" "" "$out"

summary
