#!/usr/bin/env bash
# round-lane.e2e.sh — LIVE closed-loop for the ROUND lane through the agentctl surface
# (codex leg; omp/claude live coverage rides agentctl-duplex.e2e.sh). What only this gate
# proves: the real codex binary runs headless under the real tmux supervisor via
# `agentctl start codex`, the goal executes, the deliverable freshness gate opens,
# `agentctl watch` returns typed DONE, and `agentctl steer` resumes the SAME engine
# session as round 2 (context kept). Asserts on DURABLE artifacts, never model prose.
# COST: 2 codex rounds (~30-90s each, API tokens). Pre-release gate, not a dev loop.
set -u
cd "$(dirname "$0")"
. ../lib-testkit.sh   # assertion helpers only

REPO_ROOT="$(cd ../.. && pwd)"
AW="$REPO_ROOT/skills/cto-orchestration/references/agent-watch"
AGENTCTL="$AW/agentctl"

echo "== round-lane.e2e (codex via agentctl; 2 rounds, uses API tokens) =="
command -v tmux >/dev/null 2>&1 || { echo "  SKIP: tmux not on PATH"; exit 0; }
command -v codex >/dev/null 2>&1 || { echo "  SKIP: codex CLI not on PATH"; exit 0; }
[ -x "$AGENTCTL" ] || { echo "  FAIL agentctl missing/not executable: $AGENTCTL"; exit 1; }

wait_done() { # $1 session  $2 run-dir -> typed rc; prints watch output (cap ~4min)
  AGENT_WATCH_DIR="$2" AGENT_WATCH_POLL_SECS=5 AGENT_WATCH_MAX_POLLS=48 \
    bash "$AGENTCTL" watch "$1" 2>&1
}

WT="$(mktemp -d "${TMPDIR:-/tmp}/e2e-round-codex.XXXXXX")"
TMPRUN="$(mktemp -d "${TMPDIR:-/tmp}/e2e-roundrun.XXXXXX")"
SESSION="e2e-round-codex-$$"
cat > "$WT/E2E_GOAL.md" <<'EOF'
Use your file-writing tool to create a file named GOAL_DONE.marker in the current directory,
containing exactly the word: done
Then stop. Do not do anything else.
EOF

echo "  -- codex round 1 (start + watch, cap ~4min) --"
out="$(AGENT_WATCH_DIR="$TMPRUN" bash "$AGENTCTL" start codex "$SESSION" "$WT" \
      --goal "$WT/E2E_GOAL.md" --deliverable "GOAL_DONE.marker" \
      --dangerously-bypass-approvals-and-sandbox 2>&1)"; rc=$?
chk_eq "codex: start rc0 (returns immediately)" 0 "$rc"
chk_contains "codex: routed to round lane" "round 1 started" "$out"
wout="$(wait_done "$SESSION" "$TMPRUN")"; wrc=$?
chk_eq "codex: watch typed DONE (exit 0)" 0 "$wrc"
chk_contains "codex: deliverable gate engaged" "deliverable fresh" "$wout"
chk_eq "codex: goal marker produced (relative-glob gate)" 1 \
  "$([ -f "$WT/GOAL_DONE.marker" ] && echo 1 || echo 0)"
chk_eq "codex: watch verdict is bounded (<4KB)" 1 "$(( ${#wout} < 4096 ? 1 : 0 ))"

echo "  -- codex round 2 (steer = resume same engine session) --"
out="$(AGENT_WATCH_DIR="$TMPRUN" bash "$AGENTCTL" steer "$SESSION" \
      -m 'Overwrite the existing file GOAL_DONE.marker in the current directory so it contains exactly the word: again — then stop.' 2>&1)"; rc=$?
chk_eq "codex: steer rc0" 0 "$rc"
chk_contains "codex: round 2 started (resume)" "round 2 started" "$out"
wout="$(wait_done "$SESSION" "$TMPRUN")"; wrc=$?
chk_eq "codex: round 2 typed DONE" 0 "$wrc"
chk_contains "codex: round 2 rewrote the marker (steer landed)" "again" \
  "$(cat "$WT/GOAL_DONE.marker" 2>/dev/null)"

out="$(AGENT_WATCH_DIR="$TMPRUN" bash "$AGENTCTL" stop "$SESSION" 2>&1)"; rc=$?
chk_eq "codex: stop rc0" 0 "$rc"
chk_eq "codex: zero tmux residue" 0 "$(tmux has-session -t "$SESSION" 2>/dev/null && echo 1 || echo 0)"
rm -rf "$WT" "$TMPRUN"

summary
