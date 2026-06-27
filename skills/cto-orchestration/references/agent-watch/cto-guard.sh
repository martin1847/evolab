#!/usr/bin/env bash
# cto-guard — single consolidated hook for cto-orchestration's enforcement layer.
# Wire the SAME script to both events in .claude/settings.json:
#   PreToolUse  matcher "Bash"        -> deny shell-backgrounding (&) and naive "idle==done" pollers
#   PostToolUse matcher "Agent|Task"  -> remind to set a deadline watch for browser/E2E subagents
# Dispatches internally on hook_event_name + tool_name — one script consolidates three enforcements
# (shell-& deny + naive idle-poller deny + browser-subagent watch reminder). Rationale: cto SKILL §1.4 —
# don't rely on fragile completion signals (shell-& orphan / idle / black-holing auto-notify); these
# decay as prose, so enforce at tool-call time. Deny = exit 2 + stderr; reminder = stdout.
set -u
input="$(cat)"
read -r EVENT TOOL < <(printf '%s' "$input" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(d.get("hook_event_name",""), d.get("tool_name",""))
' 2>/dev/null) || exit 0

field(){ printf '%s' "$input" | python3 -c "import sys,json;ti=json.load(sys.stdin).get('tool_input',{});print((ti.get('$1','') or '').replace(chr(10),' '))" 2>/dev/null; }

if [ "$EVENT" = "PreToolUse" ] && [ "$TOOL" = "Bash" ]; then
  cmd="$(field command)"; [ -n "$cmd" ] || exit 0
  # (1) trailing shell-& backgrounding -> orphan (no completion callback). Allow && / 2>&1 / quoted &.
  if printf '%s' "$cmd" | grep -Eq '(^|[^&])&[[:space:]]*(disown[[:space:]]*)?$' \
     || printf '%s' "$cmd" | grep -Eq '&[[:space:]]*disown[[:space:]]*$'; then
    echo "DENY: trailing shell & -> ORPHAN (no completion callback; wrapper falsely reports done). Drop the & and use the Bash tool run_in_background:true instead." >&2
    exit 2
  fi
  # (2) naive "idle==done" poller: loop + capture-pane + busy/idle grep, concluding from idle-absence
  #     with NO positive-evidence check (git deliverable OR pane Verdict/prompt marker).
  has_loop=$(printf '%s' "$cmd"        | grep -cE '\b(for|while)\b')
  has_capture=$(printf '%s' "$cmd"     | grep -cE 'capture-pane|tmux .*capture')
  has_idle=$(printf '%s' "$cmd"        | grep -ciE 'Working|Esc to interrupt|busy|idle|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏')
  has_positive=$(printf '%s' "$cmd"    | grep -ciE 'git diff --stat|git log[^|]*\.\.HEAD|--oneline|ALL PARTS DONE|Verdict|approve|request-changes|Would you like to run|APPEARED|COMMIT_|PROMPT|SIGNAL_FOUND')
  if [ "$has_loop" -ge 1 ] && [ "$has_capture" -ge 1 ] && [ "$has_idle" -ge 1 ] && [ "$has_positive" -eq 0 ]; then
    echo "DENY: hand-rolled 'idle==done' poller (loop+capture-pane+idle grep, no positive-evidence check). idle≠done — staged tasks idle at every commit boundary. Add a POSITIVE check: git deliverable (git diff --stat / git log ..HEAD) for agent completion, or a pane grep for Verdict/prompt for reviews." >&2
    exit 2
  fi
  exit 0
fi

if [ "$EVENT" = "PostToolUse" ] && { [ "$TOOL" = "Agent" ] || [ "$TOOL" = "Task" ]; }; then
  prompt="$(field prompt)"
  printf '%s' "$prompt" | grep -qiE 'playwright|chrome-?devtools|browser|E2E|screenshot|navigate|dev server|localhost:[0-9]|vite|npm run dev|pnpm .*dev' || exit 0
  cat <<'MSG'
[browser/long subagent launched] Its completion notification can BLACK-HOLE (a live Playwright session /
dev server / bg fork keeps it from firing — you'll blind-wait forever). DO NOW, don't rely on the auto-notify:
set a deadline-bounded background watch on POSITIVE evidence (output-file growth / new screenshots / a
milestone SendMessage); if it goes quiet past the deadline, SendMessage to poke it, then kill+relaunch
rather than wait. (cto SKILL §1.4 / §7.)
MSG
  exit 0
fi
exit 0
