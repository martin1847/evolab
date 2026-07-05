#!/usr/bin/env bash
# dispatch-goal.e2e.sh — LIVE closed-loop for the fused `dispatch --goal` flow (SKILL §1.4).
# The hermetic suite proves the ORCHESTRATION logic (launch→send→verify→watch, the 3-tier
# hook check, goal pre-flight, trust auto-answer) with a FAKE tmux. What no test covered until
# now: the hook-primary sentinel LIFECYCLE against a REAL agent in a REAL tmux — the agent's
# lifecycle hook actually emitting WORKING/DONE to the events file, and `watch` reading it.
# guard-wire tests PreToolUse deny; onboard tests produced files; neither exercises agent-watch.
#
# This dispatches a real interactive `claude` in tmux with a trivial goal (write a marker file),
# and asserts on DURABLE artifacts — the events sentinel + the marker — never on model prose.
# COST: one real claude session in tmux (~1-3 min, API tokens). Pre-release gate, not a dev loop.
set -u
cd "$(dirname "$0")"
. ../lib-testkit.sh   # assertion helpers only

REPO_ROOT="$(cd ../.. && pwd)"
AW="$REPO_ROOT/skills/cto-orchestration/references/agent-watch"
DISPATCH="$AW/dispatch"

echo "== dispatch-goal.e2e (live claude session in tmux; ~1-3min, uses API tokens) =="
command -v tmux >/dev/null 2>&1 || { echo "  SKIP: tmux not on PATH"; exit 0; }
[ -x "$DISPATCH" ] || { echo "  FAIL dispatch missing/not executable: $DISPATCH"; exit 1; }

WT="$(mktemp -d "${TMPDIR:-/tmp}/e2e-dispgoal.XXXXXX")"
TMPRUN="$(mktemp -d "${TMPDIR:-/tmp}/e2e-awrun.XXXXXX")"   # isolate the events dir from ~/.agents/run
export AGENT_WATCH_DIR="$TMPRUN"
SESSION="e2e-dispgoal-$$"
cleanup() {
  bash "$AW/teardown" "$SESSION" "$WT" >/dev/null 2>&1 || true
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$WT" "$TMPRUN"
  # claude writes orchestrator memory OUTSIDE the repo (~/.claude/projects/<flattened-cwd>);
  # flattening turns '.' into '-' — sweep by the translated tmpdir basename.
  find "$HOME/.claude/projects" -maxdepth 1 -type d \
    -name "*$(basename "$WT" | tr '.' '-')*" -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup EXIT

# a trivial, deterministic goal: one tool call (Write) → one marker file, then stop.
GOAL="$WT/E2E_GOAL.md"
cat > "$GOAL" <<'EOF'
Use the Write tool to create a file named GOAL_DONE.marker in the current directory,
containing exactly the word: done
Then stop. Do not do anything else.
EOF

# Fused one-call dispatch: launch real interactive claude in tmux, deliver the goal, verify the
# hook, hand off to watch — run in FOREGROUND under a timeout (e2e may block; watch exits on DONE).
# --dangerously-skip-permissions so the Write tool runs unattended (PostToolUse → WORKING sentinel).
echo "  dispatching (timeout 240s)…"
out="$(cd "$WT" && timeout 240 bash "$DISPATCH" claude "$SESSION" "$WT" \
  --dangerously-skip-permissions --goal "$GOAL" 2>&1)"

EV="$TMPRUN/$SESSION.events"

# ① real send-path: the fused verify loop reached a positive tier (sentinel or busy pane),
#    NOT the alarm — proves goal delivery + hook/pane observation on a real session.
chk_contains "fused verify hit a positive tier" "hook: " "$out"
chk_eq "verify did NOT hit the alarm tier" 0 "$(printf '%s' "$out" | grep -c 'NO sentinel after 12s and pane not busy' || true)"

# ② fused flow handed off to watch (the launch+send+verify+watch chain completed as one call).
chk_contains "fused flow handed off to watch" "handing off to watch" "$out"

# ③ CORE new coverage: the agent's lifecycle hook really emitted to the events sentinel.
#    PostToolUse→WORKING on the Write call; Stop→DONE at turn end. Both are durable file evidence.
chk_eq "events sentinel file was created" 1 "$([ -f "$EV" ] && echo 1 || echo 0)"
chk_contains "hook emitted WORKING to sentinel (PostToolUse真送达)" "WORKING" "$(cat "$EV" 2>/dev/null)"
chk_contains "hook emitted DONE to sentinel (Stop→watch terminal)" "DONE" "$(cat "$EV" 2>/dev/null)"

# ④ end-to-end: the agent really executed the goal (durable marker), not just went WORKING.
chk_eq "agent produced the goal's marker file" 1 "$([ -f "$WT/GOAL_DONE.marker" ] && echo 1 || echo 0)"

summary
