#!/usr/bin/env bash
# dispatch-goal.e2e.sh — LIVE closed-loop for the DEFAULT (headless exec) dispatch lane,
# run as a FULL ENGINE MATRIX: claude + omp + codex (a leg skips only if its CLI is absent).
# The hermetic suite proves routing/classify logic with a FAKE tmux; what only this gate
# proves: each real engine actually runs headless under the real tmux supervisor, the goal
# executes, the deliverable freshness gate opens, and `watch` returns typed DONE.
# The claude leg additionally proves round-2 steering (send -> engine resume, same session).
# TUI-lane matrix lives in dispatch-goal-tui.e2e.sh (best-effort, E2E_TUI=1 to run).
# Asserts on DURABLE artifacts (marker file + typed exit codes), never on model prose.
# COST: up to 4 engine rounds (~30-90s each, API tokens). Pre-release gate, not a dev loop.
set -u
cd "$(dirname "$0")"
. ../lib-testkit.sh   # assertion helpers only

REPO_ROOT="$(cd ../.. && pwd)"
AW="$REPO_ROOT/skills/cto-orchestration/references/agent-watch"
DISPATCH="$AW/dispatch"

echo "== dispatch-goal.e2e (headless exec engine matrix; up to 4 rounds, uses API tokens) =="
command -v tmux >/dev/null 2>&1 || { echo "  SKIP: tmux not on PATH"; exit 0; }
[ -x "$DISPATCH" ] || { echo "  FAIL dispatch missing/not executable: $DISPATCH"; exit 1; }

wait_done() { # $1 session  $2 run-dir -> typed rc; prints watch output (cap ~4min)
  AGENT_WATCH_DIR="$2" AGENT_WATCH_POLL_SECS=5 AGENT_WATCH_MAX_POLLS=48 \
    bash "$AW/watch" "$1" 2>&1
}

run_leg() {  # run_leg <engine> [extra engine flags...]
  local engine="$1"; shift
  if ! command -v "$engine" >/dev/null 2>&1; then
    echo "  [skip] $engine CLI not on PATH — leg skipped"; return 0
  fi
  local WT TMPRUN SESSION out rc wout wrc
  WT="$(mktemp -d "${TMPDIR:-/tmp}/e2e-dx-$engine.XXXXXX")"
  TMPRUN="$(mktemp -d "${TMPDIR:-/tmp}/e2e-dxrun.XXXXXX")"
  SESSION="e2e-dx-$engine-$$"
  cat > "$WT/E2E_GOAL.md" <<'EOF'
Use your file-writing tool to create a file named GOAL_DONE.marker in the current directory,
containing exactly the word: done
Then stop. Do not do anything else.
EOF
  echo "  -- leg: $engine (launch + watch, cap ~4min) --"
  # DEFAULT surface on purpose: no lane env — this gate proves what a consumer gets.
  out="$(AGENT_WATCH_DIR="$TMPRUN" bash "$DISPATCH" "$engine" "$SESSION" "$WT" \
        --goal "$WT/E2E_GOAL.md" --deliverable "$WT/GOAL_DONE.marker" "$@" 2>&1)"; rc=$?
  chk_eq "$engine: launch rc0 (returns immediately)" 0 "$rc"
  chk_contains "$engine: routed to exec lane (round 1)" "round 1 started" "$out"
  wout="$(wait_done "$SESSION" "$TMPRUN")"; wrc=$?
  chk_eq "$engine: watch typed DONE (exit 0)" 0 "$wrc"
  chk_contains "$engine: deliverable gate engaged" "deliverable fresh" "$wout"
  chk_eq "$engine: goal marker produced" 1 "$([ -f "$WT/GOAL_DONE.marker" ] && echo 1 || echo 0)"

  # claude leg: round-2 steering — send resumes the SAME engine session (context kept)
  if [ "$engine" = claude ]; then
    cat > "$WT/E2E_ROUND2.md" <<'EOF'
Overwrite the existing file GOAL_DONE.marker in the current directory so it contains exactly
the word: again
Then stop.
EOF
    out="$(AGENT_WATCH_DIR="$TMPRUN" bash "$DISPATCH" send "$SESSION" -f "$WT/E2E_ROUND2.md" 2>&1)"; rc=$?
    chk_eq "claude: resume round rc0" 0 "$rc"
    chk_contains "claude: round 2 started (resume)" "round 2 started" "$out"
    wout="$(wait_done "$SESSION" "$TMPRUN")"; wrc=$?
    chk_eq "claude: round 2 typed DONE" 0 "$wrc"
    chk_contains "claude: round 2 rewrote the marker (steering landed)" "again" "$(cat "$WT/GOAL_DONE.marker" 2>/dev/null)"
  fi

  AGENT_WATCH_DIR="$TMPRUN" bash "$AW/teardown" "$SESSION" "$WT" >/dev/null 2>&1 || true
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$WT" "$TMPRUN"
  find "$HOME/.claude/projects" -maxdepth 1 -type d \
    -name "*$(basename "$WT" | tr '.' '-')*" -exec rm -rf {} + 2>/dev/null || true
}

# economy models where the id is known-safe; omp keeps its proven exact id (fuzzy ids can
# open an interactive picker — and this gate proves lane machinery, not model quality).
run_leg claude --dangerously-skip-permissions --model haiku
run_leg omp --auto-approve --model=anthropic/claude-opus-4-8
run_leg codex --dangerously-bypass-approvals-and-sandbox

summary
