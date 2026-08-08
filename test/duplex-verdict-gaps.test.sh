#!/usr/bin/env bash
# duplexctl classify — watch verdict gaps (field incident, upstream seat, 2026-08-08):
#
#  A. a claude `result` frame ends the TURN, not the round — pending background
#     tasks auto re-invoke the harness with no steer involved, so idle-in-the-gap
#     must NOT read DONE (the orchestrator tore down an environment the engine's
#     backgrounded verification was still using).
#  B. RUNNING could not tell "thinking" from "wedged": stagnant events stream AND
#     no descendant beyond the engine under the pane = STALLED-STREAM 11. Both
#     legs required; every ambiguity (fresh stream, tool child, no pane_pid,
#     probe failure, disabled window) reads ALIVE — 宁钝勿敏.
#
# Harness: no engines, no real tmux — classify driven on hand-built session state
# (same stance as duplexctl-timeout.test.sh).
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

DUPLEXCTL="$AW_DIR/duplexctl.py"

seed_session() { # $1 name  $2 engine  $3 cwd  [$4 pane_pid]
  { printf 'engine=%s\ncwd=%s\n' "$2" "$3"
    [ -n "${4:-}" ] && printf 'pane_pid=%s\n' "$4"
  } > "$WATCH_RUN_DIR/$1.duplex.meta"
  : > "$WATCH_RUN_DIR/$1.duplex.round-started"
  : > "$WATCH_RUN_DIR/$1.duplex.events.jsonl"
  mkfifo "$WATCH_RUN_DIR/$1.duplex.in" 2>/dev/null || true
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start "$1" >/dev/null 2>&1
}
ev() { printf '%s\n' "$2" >> "$WATCH_RUN_DIR/$1.duplex.events.jsonl"; }
run_classify() { out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify "$1" 2>&1)"; rc=$?; }

sandbox_new
export FAKE_TMUX_HASSESSION=0   # pane alive: classify must reach the projector
WT="$SANDBOX/wt"; mkdir -p "$WT"

echo "== A. result frame + pending background tasks ≠ DONE =="

seed_session bgA claude "$WT"
ev bgA '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","description":"gate run"},{"task_id":"t2","description":"waiter"}]}'
ev bgA '{"type":"result","is_error":false,"result":"turn done, gates still running"}'
run_classify bgA
chk_eq "A1 pending tasks keep classify RUNNING (10), not DONE" 10 "$rc"
chk_contains "A1 verdict names the pending background tasks" "background task" "$out"
chk_contains "A1 verdict says not terminal" "not terminal" "$out"

ev bgA '{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"completed"}}'
run_classify bgA
chk_eq "A2 partially retired set still RUNNING" 10 "$rc"

# real stream shape: retirements arrive, the harness auto-continues, and the
# continued turn ends in a NEW result frame — only then is idle terminal
ev bgA '{"type":"system","subtype":"task_notification","task_id":"t2","status":"completed"}'
ev bgA '{"type":"result","is_error":false,"result":"continued turn done"}'
run_classify bgA
chk_eq "A3 all tasks terminal + fresh result → DONE" 0 "$rc"

# snapshot-replace semantics: a later EMPTY background_tasks_changed clears the set
seed_session bgB claude "$WT"
ev bgB '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t9","description":"x"}]}'
ev bgB '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
ev bgB '{"type":"result","is_error":false,"result":"done"}'
run_classify bgB
chk_eq "A4 empty snapshot replaces the set → DONE" 0 "$rc"

# an unknown task status keeps the id pending: fail toward RUNNING, never premature DONE
seed_session bgC claude "$WT"
ev bgC '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t3","description":"x"}]}'
ev bgC '{"type":"system","subtype":"task_updated","task_id":"t3","patch":{"status":"paused"}}'
ev bgC '{"type":"result","is_error":false,"result":"done"}'
run_classify bgC
chk_eq "A5 unknown task status stays pending → RUNNING" 10 "$rc"

echo "== B. STALLED-STREAM: stagnant stream + no descendant beyond the engine =="

# quiescent pane shape: a bare process with zero descendants (pane→engine, engine idle)
/bin/sleep 300 >/dev/null 2>&1 & QPID=$!
seed_session stA claude "$WT" "$QPID"
ev stA '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
touch -t 202001010000 "$WATCH_RUN_DIR/stA.duplex.events.jsonl"
run_classify stA
chk_eq "B1 stagnant + quiescent pane → STALLED-STREAM 11" 11 "$rc"
chk_contains "B1 verdict names salvage-then-stop" "salvage" "$out"
chk_contains "B1 verdict names the tunable" "AGENT_WATCH_STALL_MINS" "$out"

# alive guard: a running tool is the engine's child (2nd descendant of the pane) —
# outer bash = pane shell, inner bash = engine, sleep = tool (`; true` defeats exec)
bash -c 'bash -c "/bin/sleep 300; true"; true' >/dev/null 2>&1 & TPID=$!
seed_session stB claude "$WT" "$TPID"
ev stB '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
touch -t 202001010000 "$WATCH_RUN_DIR/stB.duplex.events.jsonl"
run_classify stB
chk_eq "B2 tool child under the engine keeps RUNNING" 10 "$rc"

# alive guard: fresh stream (thinking model keeps the file moving) → never stalls
seed_session stC claude "$WT" "$QPID"
ev stC '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
run_classify stC
chk_eq "B3 fresh stream stays RUNNING" 10 "$rc"

# alive guard: no pane_pid recorded → probe unavailable → alive
seed_session stD claude "$WT"
ev stD '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
touch -t 202001010000 "$WATCH_RUN_DIR/stD.duplex.events.jsonl"
run_classify stD
chk_eq "B4 no pane_pid → RUNNING (probe ambiguity reads alive)" 10 "$rc"

# disable switch: 0 turns the window off entirely
seed_session stE claude "$WT" "$QPID"
ev stE '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
touch -t 202001010000 "$WATCH_RUN_DIR/stE.duplex.events.jsonl"
out="$(AGENT_WATCH_STALL_MINS=0 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify stE 2>&1)"; rc=$?
chk_eq "B5 AGENT_WATCH_STALL_MINS=0 disables the stall verdict" 10 "$rc"

{ kill "$QPID" "$TPID"; wait "$QPID" "$TPID"; } 2>/dev/null
rm -rf "$SANDBOX"
summary
