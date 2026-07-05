#!/usr/bin/env bash
# dispatch-goal.e2e.sh — LIVE closed-loop for the fused `dispatch --goal` flow (SKILL §1.4),
# run as a FULL AGENT MATRIX: claude + omp + codex (a leg skips only if its CLI is absent).
# The hermetic suite proves orchestration logic with a FAKE tmux; what only this gate proves:
# the hook-primary sentinel LIFECYCLE against each real agent in real tmux — hooks actually
# emitting WORKING/DONE to the events file, trust prompts auto-answered, goal really executed.
# Per-agent hook mechanisms differ (claude settings.json / omp --hook flag / codex hooks.json
# + trust), so one green agent does NOT prove the others — hence the matrix (v1.3.0's claude
# trust-gate bug was exactly a leg nobody ran).
# Asserts on DURABLE artifacts (events sentinel + marker file), never on model prose.
# COST: up to 3 real agent sessions (~1-3 min each, API tokens). Pre-release gate, not a dev loop.
set -u
cd "$(dirname "$0")"
. ../lib-testkit.sh   # assertion helpers only

REPO_ROOT="$(cd ../.. && pwd)"
AW="$REPO_ROOT/skills/cto-orchestration/references/agent-watch"
DISPATCH="$AW/dispatch"

echo "== dispatch-goal.e2e (live agent matrix in tmux; up to 3 sessions, uses API tokens) =="
command -v tmux >/dev/null 2>&1 || { echo "  SKIP: tmux not on PATH"; exit 0; }
[ -x "$DISPATCH" ] || { echo "  FAIL dispatch missing/not executable: $DISPATCH"; exit 1; }

run_leg() {  # run_leg <agent> <sentinel:strict|none> [extra agent flags...]
  local agent="$1" sentinel="$2"; shift 2
  if ! command -v "$agent" >/dev/null 2>&1; then
    echo "  [skip] $agent CLI not on PATH — leg skipped"; return 0
  fi
  local WT TMPRUN SESSION EV out
  WT="$(mktemp -d "${TMPDIR:-/tmp}/e2e-dg-$agent.XXXXXX")"
  TMPRUN="$(mktemp -d "${TMPDIR:-/tmp}/e2e-awrun.XXXXXX")"
  SESSION="e2e-dg-$agent-$$"
  EV="$TMPRUN/$SESSION.events"
  cat > "$WT/E2E_GOAL.md" <<'EOF'
Use your file-writing tool to create a file named GOAL_DONE.marker in the current directory,
containing exactly the word: done
Then stop. Do not do anything else.
EOF
  echo "  -- leg: $agent (timeout 240s) --"
  out="$(cd "$WT" && AGENT_WATCH_DIR="$TMPRUN" timeout 240 \
        bash "$DISPATCH" "$agent" "$SESSION" "$WT" "$@" --goal "$WT/E2E_GOAL.md" 2>&1)"
  # snapshot the sentinel BEFORE teardown — teardown deletes the events file
  ev_content="$(cat "$EV" 2>/dev/null)"
  # cleanup this leg regardless of assertions (session/dirs; claude also leaves ~/.claude/projects memory)
  AGENT_WATCH_DIR="$TMPRUN" bash "$AW/teardown" "$SESSION" "$WT" >/dev/null 2>&1 || true
  tmux kill-session -t "$SESSION" 2>/dev/null || true

  # ① verify loop landed on a positive tier — never the alarm
  chk_contains "$agent: verify reported a tier" "hook: " "$out"
  chk_eq "$agent: no alarm tier" 0 "$(printf '%s' "$out" | grep -c 'NO sentinel after 12s and pane not busy' || true)"
  # ② fused chain completed launch→send→verify→watch as ONE call
  chk_contains "$agent: handed off to watch" "handing off to watch" "$out"
  # ③ hook lifecycle — per-agent expectation:
  #    strict = agent's hook MUST write the sentinel (claude settings.json / omp --hook).
  #    none   = KNOWN BROKEN upstream: codex 0.142.3 no longer fires project .codex/hooks.json
  #             (flag accepted, global-masking A/B-refuted 2026-07-05; agent works, watch scrapes —
  #             the designed degradation). The CANARY below asserts the sentinel stays EMPTY: the
  #             day codex hooks revive, the canary goes RED → flip this leg back to strict.
  if [ "$sentinel" = strict ]; then
    chk_contains "$agent: hook emitted WORKING" "WORKING" "$ev_content"
    chk_contains "$agent: hook emitted DONE" "DONE" "$ev_content"
  else
    chk_eq "$agent: sentinel still silent (canary — if RED, codex hooks revived: make this leg strict)" "" "$ev_content"
  fi
  # ④ the goal really executed (durable artifact, not prose)
  chk_eq "$agent: goal marker produced" 1 "$([ -f "$WT/GOAL_DONE.marker" ] && echo 1 || echo 0)"

  rm -rf "$WT" "$TMPRUN"
  find "$HOME/.claude/projects" -maxdepth 1 -type d \
    -name "*$(basename "$WT" | tr '.' '-')*" -exec rm -rf {} + 2>/dev/null || true
}

run_leg claude strict --dangerously-skip-permissions
run_leg omp strict --auto-approve
run_leg codex none --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust

summary
