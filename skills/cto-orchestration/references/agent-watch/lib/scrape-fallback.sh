#!/usr/bin/env bash
# Watcher template — poll a tmux agent session, report a TYPED terminal state.
# POSIX-ish bash (no zsh-isms); works under bash 3.2+ (macOS) and modern Linux bash.
# Usage: scrape-fallback.sh <tmux-session> [busy-marker] [shell-regex]
#   omp busy marker:   '⟦esc⟧'
#   codex busy marker: 'esc to interrupt'
# Run via the orchestrator's background-task mechanism so completion notifies you.
# Tune sleep to the expected task length (45s default; cache-window aware).
#
# WHY THIS IS MORE THAN IDLE DETECTION (root cause, learned the hard way):
#   The tmux drive-chain has NO failure signal. `send-keys` and `capture-pane`
#   succeed as long as the SESSION exists — they do not care whether an agent is
#   actually alive behind it. If omp/codex died or never started, capture-pane
#   returns "success + an empty/shell screen", which naive idle-detection reads
#   as "no busy marker => DONE". A dead agent gets mis-reported as a completed one.
#   FIX: never infer DONE from marker-absence alone. Require POSITIVE liveness —
#   the agent's TUI must still be the session's foreground process.
#
# Exit codes (orchestrator dispatches on these — DONE is only one of eight):
#   0 IDLE/DONE   2 AGENT DEAD (exited to shell)   3 SUSPECTED HANG
#   1 SESSION GONE   4 WAITING FOR INPUT   5 STALLED-EXTERNAL (provider-error retry-loop)
#   6 IDLE-NO-DELIVERABLE   7 WATCH-TIMEOUT

SESSION="${1:?usage: scrape-fallback.sh <session> [marker] [shell-regex]}"
MARKER="${2:-⟦esc⟧}"
# Foreground command name when the agent process has EXITED back to its shell.
# CALIBRATE ONCE PER ENVIRONMENT (like the busy marker): while the agent is
# live+idle, run  tmux display-message -p -t <session> '#{pane_current_command}'
# — it should print the agent/TUI process (node/omp/python/…), NOT a shell.
# When pane_current_command matches this regex, the agent is GONE, not done.
# (While the agent shells out to git/pytest/etc the foreground is that child,
#  not the shell, so real sub-work is not mistaken for death.)
SHELL_RE="${3:-^(-?zsh|-?bash|-?sh|login)$}"
# Interactive-prompt patterns => agent is PAUSED waiting for a human, which also
# shows "no busy marker". This is WAITING, not DONE. Heuristic, checked only when
# idle and only on the last few lines; keep it specific to avoid agents that
# merely print y/n mid-analysis.
# Includes TUI radio-select menus (e.g. omp): a settled menu shows the selected
# option as a filled radio '◉' plus an arrow-nav hint '↑/↓' — both distinctive
# glyphs agents don't emit mid-stream, so they won't false-positive while busy.
# (Learned: a radio menu has no busy marker, so marker-absence alone mis-read it
#  as DONE and the orchestrator dispatched a still-waiting agent to review.)
# NOTE on glyph-vs-text (learned the hard way): a TUI may render nav hints as TEXT
# ("up/down navigate", "enter select") rather than glyphs ("↑/↓"), and the selected
# radio "◉" can sit MANY lines above the bottom in a multi-option menu with
# descriptions. So match BOTH glyphs and the literal chrome text, and scan a WIDE
# tail (not just the last few lines) — else a settled menu reads as idle/DONE and a
# still-waiting agent gets mis-reported. Keep patterns specific to settled prompts
# (agents don't emit "up/down navigate"/"? Ask"/"Other (type your own)" mid-stream).
INPUT_RE='(\(y/n\)|\[y/N\]|Do you want to proceed|Allow this|press enter|❯ [0-9]|[◉○]|↑/↓|up/down navigate|enter (select|to confirm)|esc cancel|Other \(type your own\)|\? Ask|password:)'
# Provider-error retry-loop: agent is BUSY (marker present) but hot-retrying a TRANSIENT
# provider error (overload / rate-limit / 5xx). The screen keeps repainting new error lines,
# so the hang heuristic (frozen screen) never trips and no DONE ever comes — the orchestrator
# waits silently (learned the hard way: ~13min on overloaded_error). Pattern is SPECIFIC to
# error chrome (not bare "error" an agent writes while analyzing) + gated on BUSY + repetition.
# Override via AGENT_WATCH_EXT_ERR_RE.
EXT_ERR_RE="${AGENT_WATCH_EXT_ERR_RE:-(overloaded_error|rate_limit_error|stream error|429 Too Many|529 |Too Many Requests|insufficient_quota|service unavailable|Overloaded)}"

# (E) Deliverable gate (same semantics as watch exit 6, see watch header): idle/DONE is a
# turn/phase boundary, not task completion — codex pauses between phases with no busy marker
# (4 false IDLE/DONEs on 2026-07-05, all via this scrape path). AGENT_WATCH_DELIVERABLE=glob
# gates exit 0; AGENT_WATCH_NODELIV_POLLS (default 7 here, ~5min at 45s) then exit 6 = poke me.
DELIVERABLE="${AGENT_WATCH_DELIVERABLE:-}"
NODELIV_MAX="${AGENT_WATCH_NODELIV_POLLS:-7}"
POLL="${AGENT_WATCH_POLL_SECS:-45}"
MAX_POLLS="${AGENT_WATCH_MAX_POLLS:-130}"
# Freshness (parity with watch): when sourced from `watch`, $STAMP marks arm time and a match
# must be NEWER than it — a leftover file from a previous round must not open the gate (LH
# 2026-07-11, multi-round early exit). Standalone runs have no stamp → existence is the best we have.
deliverable_ok() {
  [ -z "$DELIVERABLE" ] && return 0
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -z "${STAMP:-}" ] || [ "$f" -nt "$STAMP" ]; then return 0; fi
  done < <(compgen -G "$DELIVERABLE" 2>/dev/null)
  return 1
}

idle=0; samehash=0; lasthash=""; exterr=0; nodeliv=0
# Immediate ARMED heartbeat so the orchestrator can confirm liveness by READING the
# output file at t=0 (ps may not show the process under the harness's backgrounding).
echo "=== [$SESSION] WATCH ARMED at $(date '+%H:%M:%S') pid $$ marker=[$MARKER] — polling every ${POLL}s ==="
i=1
while [ "$i" -le "$MAX_POLLS" ]; do
  sleep "$POLL"
  pane=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null) || { echo "[$SESSION] SESSION GONE"; exit 1; }
  cmd=$(tmux display-message -p -t "$SESSION" '#{pane_current_command}' 2>/dev/null)

  # (A) Liveness FIRST — the root-cause guard. Foreground back to a shell => the
  #     agent process exited. Dead, not done. Do NOT send it to review.
  if [[ "$cmd" =~ $SHELL_RE ]]; then
    echo "=== [$SESSION] AGENT DEAD at $(date '+%H:%M:%S') — foreground is '$cmd' (exited to shell) ==="
    echo "$pane" | tail -40
    exit 2
  fi

  if echo "$pane" | grep -qF "$MARKER"; then
    # (B) Busy. A frozen screen while "busy" => suspected hang — a live spinner /
    #     token stream / timer would keep the screen changing; total stillness won't.
    idle=0; nodeliv=0
    # Provider-error retry-loop: busy + error chrome on screen for ~2 consecutive polls
    # (~90s). Surface it (exit 5) — a retry loop keeps repainting so the frozen-screen hang
    # check below won't catch it.
    if echo "$pane" | tail -15 | grep -qiE "$EXT_ERR_RE"; then
      exterr=$((exterr+1))
      if [ $exterr -ge 2 ]; then
        echo "=== [$SESSION] STALLED-EXTERNAL at $(date '+%H:%M:%S') — provider-error retry-loop ==="
        echo "$pane" | tail -40
        exit 5
      fi
    else exterr=0; fi
    h=$(echo "$pane" | cksum)
    if [ "$h" = "$lasthash" ]; then
      samehash=$((samehash+1))
      if [ $samehash -ge 8 ]; then   # ~6 min of zero screen change while busy
        echo "=== [$SESSION] SUSPECTED HANG at $(date '+%H:%M:%S') — busy but screen frozen ~6min ==="
        echo "$pane" | tail -40
        exit 3
      fi
    else
      samehash=0; lasthash="$h"
    fi
  else
    exterr=0
    # (C) Not busy. Paused at an interactive prompt rather than finished?
    #     Scan a WIDE tail (-15): a radio menu's distinctive glyph/header can sit
    #     well above the bottom border + nav-hint lines.
    if echo "$pane" | tail -15 | grep -qE "$INPUT_RE"; then
      echo "=== [$SESSION] WAITING FOR INPUT at $(date '+%H:%M:%S') — interactive prompt, not done ==="
      echo "$pane" | tail -20
      exit 4
    fi
    # (D) Idle AND a live agent foreground (passed guard A) = really done...
    idle=$((idle+1))
    if [ $idle -ge 2 ]; then
      # (E) ...unless a declared deliverable is still missing (phase boundary, not done).
      if deliverable_ok; then
        echo "=== [$SESSION] IDLE/DONE at $(date '+%H:%M:%S') — foreground '$cmd', last pane ==="
        tmux capture-pane -t "$SESSION" -p | tail -40
        exit 0
      fi
      nodeliv=$((nodeliv+1))
      [ "$nodeliv" -eq 1 ] && echo "[$SESSION] idle but deliverable '$DELIVERABLE' missing → continuing watch"
      if [ "$nodeliv" -ge "$NODELIV_MAX" ]; then
        echo "=== [$SESSION] IDLE-NO-DELIVERABLE at $(date '+%H:%M:%S') — idle, '$DELIVERABLE' never appeared; poke the agent ==="
        tmux capture-pane -t "$SESSION" -p | tail -40
        exit 6
      fi
    fi
  fi
  # Periodic heartbeat (~every 3min) → orchestrator can Read the output file to
  # confirm the watcher is still alive without relying on ps.
  [ $((i % 4)) -eq 0 ] && echo "[$SESSION] heartbeat iter $i idle=$idle samehash=$samehash $(date '+%H:%M:%S')"
  i=$((i+1))
done
echo "=== [$SESSION] WATCHER TIMEOUT — still busy ==="
tmux capture-pane -t "$SESSION" -p | tail -25
exit 7

# Lessons baked in:
# - tmux has no failure signal: a dead/never-started agent looks like "success +
#   empty screen". DONE requires positive liveness (guard A), never marker-absence alone.
# - Don't grep for words like "blocked"/"error" as COMPLETION signals — agents WRITE
#   those while analyzing. Liveness + idle + (not waiting-input) is the done signal.
# - The waiting-input and hang checks are heuristics that REPORT a state to look at,
#   not auto-terminate anything; the orchestrator decides on exit code 3/4.
# - Background the watcher through the harness (run_in_background), not shell `&` —
#   a detached child won't notify the orchestrator when it exits.
# - One watcher per session; re-arm after each new dispatch.
