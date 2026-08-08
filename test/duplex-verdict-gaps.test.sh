#!/usr/bin/env bash
# duplexctl classify — watch verdict gaps (field incident, upstream seat, 2026-08-08):
#
#  A. a claude `result` frame ends the TURN, not the round — pending background
#     tasks auto re-invoke the harness with no steer involved, so idle-in-the-gap
#     must NOT read DONE (the orchestrator tore down an environment the engine's
#     backgrounded verification was still using).
#  B. RUNNING could not tell "thinking" from "wedged": stagnant events stream AND
#     no pane descendant YOUNGER than the silence = STALLED-STREAM 11 (in-flight
#     work spawns around the last frame; wrapper/MCP helper trees predate it).
#     Both legs required; every ambiguity (fresh stream, young child, no pane_pid,
#     probe failure, disabled window) reads ALIVE — 宁钝勿敏.
#  C. the shipped agentctl status/watch surface preserves rc 11 end to end.
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

# a task entry with no task_id can never be retired — malformed accounting must read
# RUNNING, never a premature DONE
seed_session bgD claude "$WT"
ev bgD '{"type":"system","subtype":"background_tasks_changed","tasks":[{"description":"id-less"}]}'
ev bgD '{"type":"result","is_error":false,"result":"done"}'
run_classify bgD
chk_eq "A6 malformed background-task entry stays pending → RUNNING" 10 "$rc"

echo "== B. STALLED-STREAM: stagnant stream + no in-flight descendant =="

age_events() { # $1 session  $2 seconds-ago (sub-minute precision touch can't give)
  python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time()-float(sys.argv[2]),)*2)' \
    "$WATCH_RUN_DIR/$1.duplex.events.jsonl" "$2"
}

# fake ps: full control of topology + etimes. A flat descendant-count threshold was
# refuted against LIVE panes in review (codex 11-14, claude 8 wrapper/MCP descendants),
# so these fixtures model the REAL provider tree: pane shell -> wrapper -> node ->
# engine + persistent helper, and in-flight work is told apart by AGE, not by count.
PSBIN="$SANDBOX/psbin"; mkdir -p "$PSBIN"
cat > "$PSBIN/ps" <<'FAKEPS'
#!/bin/sh
[ -n "${FAKE_PS_RC:-}" ] && exit "$FAKE_PS_RC"
cat "${FAKE_PS_FILE:?}"
FAKEPS
chmod +x "$PSBIN/ps"
ps_classify() { # $1 session (uses exported FAKE_PS_FILE / FAKE_PS_RC)
  out="$(PATH="$PSBIN:$PATH" python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify "$1" 2>&1)"; rc=$?
}

# wedged provider tree: every descendant far older than the silence (day-form etime
# exercises the parser); root present in the snapshot
cat > "$SANDBOX/ps-wedged.txt" <<'PS'
70000     1 03:25:01
70001 70000 03:25:00
70002 70001 03:25:00
70003 70002 1-02:00:00
70004 70002 03:20:00
PS
seed_session stF claude "$WT" 70000
ev stF '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
age_events stF 1200
export FAKE_PS_FILE="$SANDBOX/ps-wedged.txt"; unset FAKE_PS_RC
ps_classify stF
chk_eq "B1 wedged helper-rich tree (all older than silence) → STALLED-STREAM 11" 11 "$rc"
chk_contains "B1 verdict names salvage-then-stop" "salvage" "$out"
chk_contains "B1 verdict names the tunable" "AGENT_WATCH_STALL_MINS" "$out"

# same tree + one YOUNG in-flight tool under the engine → alive
{ cat "$SANDBOX/ps-wedged.txt"; echo "70005 70003 00:30"; } > "$SANDBOX/ps-tool.txt"
export FAKE_PS_FILE="$SANDBOX/ps-tool.txt"
ps_classify stF
chk_eq "B2 young in-flight tool keeps RUNNING despite old helpers" 10 "$rc"

# probe failure legs: each must read ALIVE, never stalled
export FAKE_PS_FILE="$SANDBOX/ps-wedged.txt" FAKE_PS_RC=1
ps_classify stF
chk_eq "B3 ps non-zero exit → RUNNING (probe failure reads alive)" 10 "$rc"
unset FAKE_PS_RC

grep -v '^70000 ' "$SANDBOX/ps-wedged.txt" > "$SANDBOX/ps-noroot.txt"
export FAKE_PS_FILE="$SANDBOX/ps-noroot.txt"
ps_classify stF
chk_eq "B4 root pid absent from snapshot (died/reused) → RUNNING" 10 "$rc"

sed 's/^70000     1 03:25:01$/70000     1 garbage/' "$SANDBOX/ps-wedged.txt" > "$SANDBOX/ps-badroot.txt"
export FAKE_PS_FILE="$SANDBOX/ps-badroot.txt"
ps_classify stF
chk_eq "B5 malformed root row → RUNNING (unparsable is not evidence)" 10 "$rc"

# R2 major mutation: the ROOT parses but a REACHABLE young tool's etime is malformed —
# dropping it silently would leave only old rows and manufacture a false 11
{ cat "$SANDBOX/ps-wedged.txt"; echo "70005 70003 garbage"; } > "$SANDBOX/ps-badchild.txt"
export FAKE_PS_FILE="$SANDBOX/ps-badchild.txt"
ps_classify stF
chk_eq "B5b malformed reachable child row → RUNNING (poisoned probe reads alive)" 10 "$rc"
export FAKE_PS_FILE="$SANDBOX/ps-wedged.txt"

# R2 blocker mutation: a long request served INSIDE an old persistent helper spawns no
# new process — the tree is identical to B1's wedge. The stream must carry the alive
# signal: an UNMATCHED tool_use (no tool_result yet) keeps RUNNING despite the old tree.
seed_session stM claude "$WT" 70000
ev stM '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"mcp_query"}]}}'
age_events stM 1200
ps_classify stM
chk_eq "B11 unmatched tool_use (in-process MCP call) → RUNNING despite wedge-shaped tree" 10 "$rc"

# ...and once the tool_result lands (matched), the same stale+old-tree state stalls
ev stM '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok"}]}}'
age_events stM 1200
ps_classify stM
chk_eq "B12 matched lifecycle + stale + old tree → STALLED-STREAM 11 (incident shape)" 11 "$rc"

# unmatched command_lifecycle is in-flight work too
seed_session stN claude "$WT" 70000
ev stN '{"type":"command_lifecycle","command_uuid":"c1","state":"started"}'
age_events stN 1200
ps_classify stN
chk_eq "B13 unmatched command_lifecycle → RUNNING" 10 "$rc"

# pending background task with a long-silent stream: harness will re-invoke — alive
seed_session stO claude "$WT" 70000
ev stO '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"tb1","description":"long gate"}]}'
ev stO '{"type":"assistant","message":{"content":[{"type":"text","text":"spawned"}]}}'
age_events stO 1200
ps_classify stO
chk_eq "B14 pending background task → RUNNING despite silence" 10 "$rc"

# codex: an unmatched item/started (running command) is in-flight; matched items with a
# stale stream and an old tree stall (a wedged engine dies mid-turn by definition,
# so an open turn alone must not veto)
seed_session cxS codex "$WT" 70000
ev cxS '{"method":"turn/started","params":{"turn":{"id":"turn-1"}}}'
ev cxS '{"method":"item/started","params":{"item":{"id":"i1"}}}'
age_events cxS 1200
ps_classify cxS
chk_eq "B15 codex unmatched item/started → RUNNING" 10 "$rc"

ev cxS '{"method":"item/completed","params":{"item":{"id":"i1"}}}'
age_events cxS 1200
ps_classify cxS
chk_eq "B16 codex matched items + stale + old tree → STALLED-STREAM 11" 11 "$rc"

# R3-1 blocker mutation: tool_use opened BEFORE a steer — the sent-offset rotates past
# it, but lifecycle must pair across the WHOLE stream, not the post-steer window
seed_session stP claude "$WT" 70000
ev stP '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu9","name":"mcp_query"}]}}'
wc -c < "$WATCH_RUN_DIR/stP.duplex.events.jsonl" | tr -d ' ' > "$WATCH_RUN_DIR/stP.duplex.sent-offset"
ev stP '{"type":"assistant","message":{"content":[{"type":"text","text":"post-steer chatter"}]}}'
age_events stP 1200
ps_classify stP
chk_eq "B17 pre-steer open tool survives sent-offset rotation → RUNNING" 10 "$rc"

# R3-2 pairing ambiguities: each must read alive, never 11
seed_session stQ claude "$WT" 70000
ev stQ '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"x"}]}}'
ev stQ '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"x"}]}}'
ev stQ '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok"}]}}'
age_events stQ 1200
ps_classify stQ
chk_eq "B18 duplicate tool_use id collapsing to closed → RUNNING (ambiguous)" 10 "$rc"

seed_session stR claude "$WT" 70000
ev stR '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"no-id"}]}}'
age_events stR 1200
ps_classify stR
chk_eq "B19 id-less tool_use → RUNNING (unpairable)" 10 "$rc"

seed_session stS claude "$WT" 70000
ev stS '{"type":"command_lifecycle","command_uuid":"c9","state":"started"}'
ev stS '{"type":"command_lifecycle","command_uuid":"c9","state":"failed"}'
age_events stS 1200
ps_classify stS
chk_eq "B20 unknown command_lifecycle state → RUNNING (not a clean close)" 10 "$rc"

seed_session stT claude "$WT" 70000
ev stT '{"type":"assistant","message":{"content":[{"type":"text","text":"quiet"}]}}'
printf 'this is not json\n' >> "$WATCH_RUN_DIR/stT.duplex.events.jsonl"
age_events stT 1200
ps_classify stT
chk_eq "B21 undecodable complete line → RUNNING (junk is ambiguity, not silence)" 10 "$rc"

# R3-3 ps snapshot mutations: malformed pid/ppid and short rows poison the whole probe
{ cat "$SANDBOX/ps-wedged.txt"; echo "bad 70001 00:01"; } > "$SANDBOX/ps-badpid.txt"
export FAKE_PS_FILE="$SANDBOX/ps-badpid.txt"
ps_classify stF
chk_eq "B22 malformed pid row → RUNNING" 10 "$rc"
{ cat "$SANDBOX/ps-wedged.txt"; echo "70005 bad 00:01"; } > "$SANDBOX/ps-badppid.txt"
export FAKE_PS_FILE="$SANDBOX/ps-badppid.txt"
ps_classify stF
chk_eq "B23 malformed ppid row → RUNNING" 10 "$rc"
{ cat "$SANDBOX/ps-wedged.txt"; echo "70005 70001"; } > "$SANDBOX/ps-short.txt"
export FAKE_PS_FILE="$SANDBOX/ps-short.txt"
ps_classify stF
chk_eq "B24 short row → RUNNING" 10 "$rc"
export FAKE_PS_FILE="$SANDBOX/ps-wedged.txt"

# codex thread scoping: with our thread in meta, a foreign completion must not close
# our item, and an UNSCOPED completion is ambiguity — both alive
seed_session cxT codex "$WT" 70000
printf 'thread=thread-1\n' >> "$WATCH_RUN_DIR/cxT.duplex.meta"
ev cxT '{"method":"item/started","params":{"threadId":"thread-1","item":{"id":"i7"}}}'
ev cxT '{"method":"item/completed","params":{"threadId":"thread-9","item":{"id":"i7"}}}'
age_events cxT 1200
ps_classify cxT
chk_eq "B25 foreign-thread completion does not close our item → RUNNING" 10 "$rc"

seed_session cxU codex "$WT" 70000
printf 'thread=thread-1\n' >> "$WATCH_RUN_DIR/cxU.duplex.meta"
ev cxU '{"method":"item/started","params":{"threadId":"thread-1","item":{"id":"i8"}}}'
ev cxU '{"method":"item/completed","params":{"item":{"id":"i8"}}}'
age_events cxU 1200
ps_classify cxU
chk_eq "B26 unscoped completion while scoping required → RUNNING (ambiguous)" 10 "$rc"

# real-process sanity: a quiescent pane with ZERO descendants still stalls,
# and a just-spawned real child (younger than any silence) keeps alive
/bin/sleep 300 >/dev/null 2>&1 & QPID=$!
seed_session stG claude "$WT" "$QPID"
ev stG '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
age_events stG 1200
run_classify stG
chk_eq "B6 real quiescent pane (no descendants) → STALLED-STREAM 11" 11 "$rc"

bash -c '/bin/sleep 300; true' >/dev/null 2>&1 & TPID=$!
seed_session stH claude "$WT" "$TPID"
ev stH '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
age_events stH 1200
run_classify stH
chk_eq "B7 real young child under the pane → RUNNING" 10 "$rc"

# alive guards: fresh stream / no pane_pid / disabled window
seed_session stC claude "$WT" "$QPID"
ev stC '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
run_classify stC
chk_eq "B8 fresh stream stays RUNNING" 10 "$rc"

seed_session stD claude "$WT"
ev stD '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
age_events stD 1200
run_classify stD
chk_eq "B9 no pane_pid → RUNNING (probe ambiguity reads alive)" 10 "$rc"

seed_session stE claude "$WT" "$QPID"
ev stE '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
age_events stE 1200
out="$(AGENT_WATCH_STALL_MINS=0 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" classify stE 2>&1)"; rc=$?
chk_eq "B10 AGENT_WATCH_STALL_MINS=0 disables the stall verdict" 10 "$rc"

echo "== C. wrapper surface: agentctl status/watch pass 11 through =="

out="$(PATH="$PSBIN:$PATH" bash "$AGENTCTL" status stF 2>&1)"; rc=$?
chk_eq "C1 agentctl status exits 11" 11 "$rc"
chk_contains "C1 status prints STALLED-STREAM" "STALLED-STREAM" "$out"

out="$(PATH="$PSBIN:$PATH" bash "$AGENTCTL" watch stF 2>&1)"; rc=$?
chk_eq "C2 agentctl watch exits 11" 11 "$rc"
chk_contains "C2 watch machine tail line" "EXIT=11" "$out"
chk_contains "C2 watch prints STALLED-STREAM" "STALLED-STREAM" "$out"
unset FAKE_PS_FILE

{ kill "$QPID" "$TPID"; wait "$QPID" "$TPID"; } 2>/dev/null
rm -rf "$SANDBOX"
summary
