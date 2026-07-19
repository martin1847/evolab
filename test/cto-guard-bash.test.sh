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
print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":ti}))' "$@"; }
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
chk_eq "send-keys CJK denied (exit 2)" 2 "$RC"; chk_contains "send-keys deny points to agentctl steer" "agentctl steer" "$ERR"
run 'tmux send-keys -t s1 Escape'
chk_eq "send-keys control key allowed" 0 "$RC"
run 'tmux send-keys -t s1 "read /tmp/goal.md" Enter'
chk_eq "send-keys short ASCII allowed" 0 "$RC"
run 'bash references/agent-watch/agentctl steer s1 -m "长中文放行指令：按评审意见回修①②"'
chk_eq "agentctl steer safe path allowed" 0 "$RC"

# Heredoc bodies are safe to ignore only when Bash disables expansion by quoting the delimiter.
quoted_heredoc="$(printf '%s\n' "cat <<'EOF'" 'tmux send-keys -t s1 "这只是文档里的提及①②③" Enter' 'EOF')"
run "$quoted_heredoc"
chk_eq "quoted heredoc body mentioning guarded command allowed" 0 "$RC"

unquoted_heredoc="$(printf '%s\n' 'cat <<EOF' '$(tmux send-keys -t s1 "这会在 heredoc 中执行①②③" Enter)' 'EOF')"
run "$unquoted_heredoc"
chk_eq "unquoted heredoc command substitution remains guarded" 2 "$RC"

guarded_after_heredoc="$(printf '%s\n' "cat <<'EOF'" 'tmux send-keys -t s1 "quoted body mention①②③" Enter' 'EOF' 'tmux send-keys -t s1 "实际执行①②③" Enter')"
run "$guarded_after_heredoc"
chk_eq "guarded command after quoted heredoc remains guarded" 2 "$RC"

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

# (3) launch without a watcher -> ALLOW + JSON reminder (`agentctl start` never auto-watches).
ctx() { printf '%s' "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit()
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }
run 'bash references/agent-watch/agentctl start omp mysess /wt --goal /tmp/g.md'
chk_eq "start w/o watch exit 0" 0 "$RC"
chk_contains "start w/o watch reminds arm watcher" "watcher" "$(ctx "$OUT")"
chk_contains "reminder names the session" "mysess" "$(ctx "$OUT")"
# start WITH watch on the same session, BACKGROUNDED -> silent (no double-nag)
run 'agentctl start omp mysess /wt --goal /tmp/g.md && bash references/agent-watch/agentctl watch mysess' 1
chk_eq "start + watch same cmd (bg) exit 0" 0 "$RC"; chk_eq "start + watch silent" "" "$OUT"

# (5) blocking `agentctl watch` in the FOREGROUND -> DENY (killed at Bash timeout, exit 143)
run 'agentctl steer mysess -f /tmp/fix.md && bash references/agent-watch/agentctl watch mysess'
chk_eq "chained foreground watch denied (field case)" 2 "$RC"; chk_contains "foreground deny names 143" "143" "$ERR"
run 'AGENT_WATCH_POLL_SECS=5 bash references/agent-watch/agentctl watch mysess'
chk_eq "env-prefixed foreground watch denied" 2 "$RC"
run 'bash references/agent-watch/dispatch-exec watch mysess'
chk_eq "internal round watch foreground denied too" 2 "$RC"
# explicit sync opt-out for shell orchestrators that run watch synchronously by design
run 'AGENT_WATCH_SYNC=1 bash references/agent-watch/agentctl watch mysess; rc=$?'
chk_eq "AGENT_WATCH_SYNC=1 foreground allowed" 0 "$RC"
# start returns after the goal frame is accepted -> foreground is fine
run 'bash references/agent-watch/agentctl start omp mysess /wt --goal /tmp/g.md'
chk_eq "start --goal foreground allowed (returns immediately)" 0 "$RC"
# path as an ARGUMENT is not an invocation (self-inflicted false positives, 2026-07-11)
run 'grep -n foo references/agent-watch/agentctl references/agent-watch/duplexctl.py'
chk_eq "agentctl path as grep arg allowed" 0 "$RC"
run 'grep -n x agent-watch/duplexctl.py agent-watch/agentctl'
chk_eq "arg after .py arg allowed (suffix trap)" 0 "$RC"
run 'agentctl status mysess'
chk_eq "one-shot status foreground allowed" 0 "$RC"
# ── (6) live e2e gates: premium orchestrator must dispatch, runner declares E2E_ECONOMY=1 ──
run 'bash test/e2e/guard-wire.e2e.sh'
chk_eq "bare e2e gate run denied" 2 "$RC"; chk_contains "e2e deny teaches dispatch+marker" "E2E_ECONOMY=1" "$ERR"
chk_contains "e2e deny carries doc pointer" "SKILL.md" "$ERR"
run "zsh -lc 'cd /repo/test/e2e && bash onboard.e2e.sh; echo RC=\$?'"
chk_eq "wrapped e2e gate run denied" 2 "$RC"
run './test/e2e/run.sh'
chk_eq "e2e run.sh denied" 2 "$RC"
run "zsh -lc 'cd /repo/test/e2e && E2E_ECONOMY=1 bash onboard.e2e.sh; echo RC=\$?'"
chk_eq "declared economy runner allowed" 0 "$RC"
# path as ARGUMENT (reading/grepping the script) is not an invocation
run 'grep -n model test/e2e/round-lane.e2e.sh'
chk_eq "e2e path as grep arg allowed" 0 "$RC"
run 'head -25 test/e2e/guard-wire.e2e.sh'
chk_eq "e2e path as head arg allowed" 0 "$RC"

# non-dispatch command -> silent
run 'git status'
chk_eq "non-dispatch silent" "" "$OUT"

# checker controls: malformed/missing/broken must not collapse into a clean allow.
run ''
chk_eq "empty command allowed" 0 "$RC"; chk_eq "empty command no stderr" "" "$ERR"
tmpe="$(mktemp)"; out="$(printf 'not json' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "malformed JSON is checker error" 2 "$rc"; chk_contains "malformed JSON marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "matching Bash missing command is checker error" 2 "$rc"; chk_contains "missing command marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":42}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "matching Bash wrong command type is checker error" 2 "$rc"; chk_contains "wrong command type marker" "CHECKER-ERROR" "$err"
tmpe="$(mktemp)"; out="$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}' | python3 "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "non-applicable Bash event stays allowed" 0 "$rc"; chk_eq "non-applicable Bash event silent" "" "$err"
tmpe="$(mktemp)"; out="$(python3 -c 'import io,re,runpy,sys; sys.stdin=io.StringIO("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}"); re.search=lambda *a,**k: (_ for _ in ()).throw(RuntimeError("boom")); runpy.run_path(sys.argv[1],run_name="__main__")' "$GUARD" 2>"$tmpe")"; rc=$?; err="$(cat "$tmpe")"; rm -f "$tmpe"
chk_eq "internal Bash checker failure exits 2" 2 "$rc"; chk_contains "internal Bash checker failure marker" "CHECKER-ERROR" "$err"

summary
