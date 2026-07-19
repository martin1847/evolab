#!/usr/bin/env bash
# agentctl-duplex.e2e.sh — LIVE closed-loop for the unified duplex lane (omp + claude + codex).
# The hermetic suite proves frames/projection/routing with fake engines; what ONLY this
# gate proves, per engine, against the real binary under the real tmux supervisor:
#   1. the long-lived native-protocol process comes up (omp rpc ready / claude stream-json)
#   2. the goal delivered as a protocol frame actually executes (deliverable appears)
#   3. `agentctl watch` returns typed DONE off protocol truth (no pane reading)
#   4. mid-session `agentctl steer` lands in the SAME live process (context kept,
#      no new engine process) — the claude leg is the FIRST live verification of
#      bare-CLI stream-json multi-turn injection (docs imply it; nothing e2e-proved it)
#   5. `agentctl stop` leaves zero tmux residue (events kept for post-mortem, then removed)
# Asserts on DURABLE artifacts (marker files + typed exits), never on model prose.
# COST: 3 engines x 2 turns (~30-90s each, API tokens). Pre-release gate, not a dev loop.
set -u
cd "$(dirname "$0")"
. ../lib-testkit.sh   # assertion helpers only

REPO_ROOT="$(cd ../.. && pwd)"
AW="$REPO_ROOT/skills/cto-orchestration/references/agent-watch"
AGENTCTL="$AW/agentctl"

echo "== agentctl-duplex.e2e (omp + claude duplex legs; uses API tokens) =="
command -v tmux >/dev/null 2>&1 || { echo "  SKIP: tmux not on PATH"; exit 0; }
[ -x "$AGENTCTL" ] || { echo "  FAIL agentctl missing/not executable: $AGENTCTL"; exit 1; }

wait_done() { # $1 session  $2 run-dir -> typed rc; prints watch output (cap ~4min)
  AGENT_WATCH_DIR="$2" AGENT_WATCH_POLL_SECS=5 AGENT_WATCH_MAX_POLLS=48 \
    bash "$AGENTCTL" watch "$1" 2>&1
}

run_leg() {  # run_leg <engine> [extra engine flags...]
  local engine="$1"; shift
  if ! command -v "$engine" >/dev/null 2>&1; then
    echo "  [skip] $engine CLI not on PATH — leg skipped"; return 0
  fi
  local WT TMPRUN SESSION out rc wout wrc
  WT="$(mktemp -d "${TMPDIR:-/tmp}/e2e-actl-$engine.XXXXXX")"
  TMPRUN="$(mktemp -d "${TMPDIR:-/tmp}/e2e-actlrun.XXXXXX")"
  SESSION="e2e-actl-$engine-$$"
  cat > "$WT/E2E_GOAL.md" <<'EOF'
Use your file-writing tool to create a file named GOAL_DONE.marker in the current directory,
containing exactly the word: done
Then stop. Do not do anything else.
EOF
  echo "  -- leg: $engine (start + watch + steer + watch, cap ~8min) --"
  out="$(AGENT_WATCH_DIR="$TMPRUN" bash "$AGENTCTL" start "$engine" "$SESSION" "$WT" \
        --goal "$WT/E2E_GOAL.md" --deliverable "GOAL_DONE.marker" "$@" 2>&1)"; rc=$?
  chk_eq "$engine: start rc0 (returns after goal frame accepted)" 0 "$rc"
  chk_contains "$engine: duplex lane announced" "duplex session" "$out"
  wout="$(wait_done "$SESSION" "$TMPRUN")"; wrc=$?
  chk_eq "$engine: watch typed DONE (exit 0)" 0 "$wrc"
  chk_eq "$engine: goal marker produced (relative-glob gate opened)" 1 \
    "$([ -f "$WT/GOAL_DONE.marker" ] && echo 1 || echo 0)"
  chk_eq "$engine: watch verdict is bounded (<4KB)" 1 "$(( ${#wout} < 4096 ? 1 : 0 ))"

  # mid-session steer into the SAME live process — the duplex lane's raison d'être
  out="$(AGENT_WATCH_DIR="$TMPRUN" bash "$AGENTCTL" steer "$SESSION" \
        -m 'Overwrite the existing file GOAL_DONE.marker in the current directory so it contains exactly the word: again — then stop.' 2>&1)"; rc=$?
  chk_eq "$engine: steer rc0" 0 "$rc"
  wout="$(wait_done "$SESSION" "$TMPRUN")"; wrc=$?
  chk_eq "$engine: post-steer watch typed DONE" 0 "$wrc"
  chk_contains "$engine: steer landed in the live session (marker rewritten)" "again" \
    "$(cat "$WT/GOAL_DONE.marker" 2>/dev/null)"

  out="$(AGENT_WATCH_DIR="$TMPRUN" bash "$AGENTCTL" stop "$SESSION" 2>&1)"; rc=$?
  chk_eq "$engine: stop rc0" 0 "$rc"
  chk_eq "$engine: zero tmux residue" 0 "$(tmux has-session -t "$SESSION" 2>/dev/null && echo 1 || echo 0)"
  chk_eq "$engine: events kept for post-mortem" 1 \
    "$([ -f "$TMPRUN/$SESSION.duplex.events.jsonl" ] && echo 1 || echo 0)"
  rm -rf "$WT" "$TMPRUN"
  find "$HOME/.claude/projects" -maxdepth 1 -type d \
    -name "*$(basename "$WT" | tr '.' '-')*" -exec rm -rf {} + 2>/dev/null || true
}

# economy models where the id is known-safe (same pinning rationale as round-lane.e2e:
# fuzzy omp ids can open an interactive picker; this gate proves lane machinery, not models).
run_leg claude --model haiku
run_leg omp --auto-approve --model=anthropic/claude-opus-4-8
run_leg codex

summary
