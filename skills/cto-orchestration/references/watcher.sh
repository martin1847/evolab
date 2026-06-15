#!/usr/bin/env bash
# Watcher template — poll a tmux agent session, report a TYPED terminal state.
# POSIX-ish bash (no zsh-isms); works under bash 3.2+ (macOS) and modern Linux bash.
# Usage: watcher.sh <tmux-session> [busy-marker] [shell-regex]
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
# Exit codes (orchestrator dispatches on these — DONE is only one of five):
#   0 IDLE/DONE   2 AGENT DEAD (exited to shell)   3 SUSPECTED HANG
#   1 SESSION GONE   4 WAITING FOR INPUT

SESSION="${1:?usage: watcher.sh <session> [marker] [shell-regex]}"
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
INPUT_RE='(\(y/n\)|\[y/N\]|Do you want to proceed|Allow this|press enter|❯ [0-9]|◉|↑/↓|password:)'

idle=0; samehash=0; lasthash=""
for i in {1..130}; do
  sleep 45
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
    idle=0
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
    # (C) Not busy. Paused at an interactive prompt rather than finished?
    if echo "$pane" | tail -6 | grep -qE "$INPUT_RE"; then
      echo "=== [$SESSION] WAITING FOR INPUT at $(date '+%H:%M:%S') — interactive prompt, not done ==="
      echo "$pane" | tail -20
      exit 4
    fi
    # (D) Idle AND a live agent foreground (passed guard A) = really done.
    idle=$((idle+1))
    if [ $idle -ge 2 ]; then
      echo "=== [$SESSION] IDLE/DONE at $(date '+%H:%M:%S') — foreground '$cmd', last pane ==="
      tmux capture-pane -t "$SESSION" -p | tail -40
      exit 0
    fi
  fi
done
echo "=== [$SESSION] WATCHER TIMEOUT — still busy ==="
tmux capture-pane -t "$SESSION" -p | tail -25

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
