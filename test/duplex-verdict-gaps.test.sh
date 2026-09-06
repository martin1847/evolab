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
# Script-dir anchored BEFORE the cd: `$0` stays relative (`test/duplex-verdict-gaps.test.sh`),
# so re-deriving `dirname "$0"` after this cd builds a second `test/` level and the fixtures
# below vanish for the repo-root entry point the contract names (review M4).
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
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

echo "== D. stop-time sentinel: events growing past the terminal marker is said out loud =="

set_mtimes() { # $1 session  $2 marker-age-secs  $3 events-age-secs (ago from now)
  python3 - "$WATCH_RUN_DIR/$1.terminal.json" "$2" "$WATCH_RUN_DIR/$1.duplex.events.jsonl" "$3" <<'PY'
import os, sys, time
now = time.time()
os.utime(sys.argv[1], (now - float(sys.argv[2]),) * 2)
os.utime(sys.argv[3], (now - float(sys.argv[4]),) * 2)
PY
}
run_stop() { # $1 session [$2 PATH-prepend dir] — splits stdout/stderr, captures rc
  if [ -n "${2:-}" ]; then
    s_out="$(PATH="$2:$PATH" bash "$AGENTCTL" stop "$1" 2>"$SANDBOX/stop-err")"; s_rc=$?
  else
    s_out="$(bash "$AGENTCTL" stop "$1" 2>"$SANDBOX/stop-err")"; s_rc=$?
  fi
  s_err="$(cat "$SANDBOX/stop-err")"
}
mksn() { # $1 session — seed + marker + result frame
  seed_session "$1" claude "$WT" 70000
  ev "$1" '{"type":"result","is_error":false,"result":"done"}'
  printf '{"stamp":"x"}\n' > "$WATCH_RUN_DIR/$1.terminal.json"
}

# late-growing events → SENTINEL on STDERR only; stop rc untouched
mksn snA; set_mtimes snA 30 0
run_stop snA
chk_eq "D1 stop rc stays 0 with sentinel firing" 0 "$s_rc"
chk_contains "D1 sentinel fires on stderr" "SENTINEL" "$s_err"
chk_not_contains "D1 sentinel does not pollute stdout" "SENTINEL" "$s_out"
chk_contains "D1 sentinel points at the replay corpus" "replay corpus" "$s_err"

# +2s boundary: delta=2 silent, delta=3 fires (the flush-race allowance is exact)
mksn snB; set_mtimes snB 100 98
run_stop snB
chk_eq "D2 delta=2 stop rc 0" 0 "$s_rc"
chk_not_contains "D2 delta=2 stays silent (flush race priced in)" "SENTINEL" "$s_err"
mksn snB2; set_mtimes snB2 100 97
run_stop snB2
chk_contains "D2b delta=3 fires" "SENTINEL" "$s_err"

# no marker (stopping a live session) → silent, rc 0
seed_session snC claude "$WT" 70000
ev snC '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
run_stop snC
chk_eq "D3 no-marker stop rc 0" 0 "$s_rc"
chk_not_contains "D3 no terminal marker → no sentinel" "SENTINEL" "$s_err"

# stat dialect matrix: BSD-shaped, GNU-shaped (failed -f pollutes stdout — the
# poisoning shape), and both-broken. Fires on both working dialects; broken probe
# degrades SILENTLY and must never touch stop's rc.
STATBIN="$SANDBOX/statbin"; mkdir -p "$STATBIN"
cat > "$STATBIN/stat" <<'FAKESTAT'
#!/bin/sh
mode="${FAKE_STAT_MODE:?}"; flag="$1"; file="$3"
real() { python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$1"; }
case "$mode:$flag" in
  bsd:-f) real "$file";;
  bsd:*)  echo "stat: illegal option" >&2; exit 1;;
  gnu:-c) real "$file";;
  gnu:*)  printf 'File: "junk"\n    ID: 100 Namelen: 255\n'; exit 1;;
  *)      printf 'garbage\n'; exit 1;;
esac
FAKESTAT
chmod +x "$STATBIN/stat"

for dialect in bsd gnu; do
  mksn "sn_$dialect"; set_mtimes "sn_$dialect" 30 0
  export FAKE_STAT_MODE="$dialect"
  run_stop "sn_$dialect" "$STATBIN"
  chk_eq "D4 $dialect dialect stop rc 0" 0 "$s_rc"
  chk_contains "D4 $dialect dialect sentinel fires" "SENTINEL" "$s_err"
done
mksn snZ; set_mtimes snZ 30 0
export FAKE_STAT_MODE=broken
run_stop snZ "$STATBIN"
chk_eq "D5 broken stat probes keep stop rc 0" 0 "$s_rc"
chk_not_contains "D5 broken probes degrade silently, never a false sentinel" "SENTINEL" "$s_err"
unset FAKE_STAT_MODE

echo "== E. omp: THIS ROUND's error frames are a verdict, not silence =="
# Field, 2026-09-04, two REAL event streams (trimmed into duplex-fixtures/, home paths
# redacted, frame shapes untouched): a `402 Insufficient Balance` assistant frame, and a
# prompt rejected with `No API key found for anthropic` AFTER an earlier success:true on the
# same request id. Both were projected IDLE and published DONE — the watcher steered into a
# dead engine twice. classify is driven on hand-built session state as everywhere else here;
# the ONE thing that cannot be faked with a file is omp's correlated get_state, so a minimal
# answerer holds the fifo's read end and replies on the real wire.
# Same sandbox as the sections above (the sleepers they hold are torn down at the end of the
# file); every session name here is new, so nothing is shared but the run dir itself.
FIXD="$HERE/duplex-fixtures"
ANSWERERS=""
omp_answer() { # $1 session  [$2 "stream" = answer isStreaming=true] — answer get_state on the
                # wire until the session is torn down
  python3 - "$WATCH_RUN_DIR/$1.duplex.in" "$WATCH_RUN_DIR/$1.duplex.events.jsonl" \
           "${2:-idle}" <<'EOF' &
import json, sys, time
fifo, events, mode = sys.argv[1], sys.argv[2], sys.argv[3]
deadline = time.time() + 120
while time.time() < deadline:
    try:
        with open(fifo, "r") as fh:          # blocks for a writer; EOF when it closes again
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                with open(events + ".seen", "a") as sn:
                    sn.write(line + "\n")    # every frame that reached the wire
                if msg.get("type") not in ("get_state", "get-state"):
                    continue
                with open(events, "a") as ev:
                    ev.write(json.dumps({
                        "id": msg.get("id"), "type": "response", "command": "get_state",
                        "success": True,
                        "data": {"isStreaming": mode == "stream", "isCompacting": False,
                                 "sessionId": "fixture", "messageCount": 2,
                                 "queuedMessageCount": 0}}) + "\n")
    except OSError:
        time.sleep(0.05)
EOF
  ANSWERERS="$ANSWERERS $!"
}
omp_session() { # $1 name  [$2 "stream"] — a seeded omp session with a live get_state answerer
  seed_session "$1" omp "$WT"
  omp_answer "$1" "${2:-idle}"
}
cut_round() { # $1 name — everything written so far belongs to a PREVIOUS round
  python3 -c 'import os, sys; print(os.path.getsize(sys.argv[1]))' \
    "$WATCH_RUN_DIR/$1.duplex.events.jsonl" > "$WATCH_RUN_DIR/$1.duplex.sent-offset"
}
cut_round_req() { # $1 name  $2 request id — a round cut WITH the sender's record of it
  # exactly what `commit_round_state` commits: the new offset, the round number the meta then
  # carries, and the id of the frame that opened that round. The projector matches on the ROUND
  # (two rounds can open at the same offset), so a row either provably belongs to the current
  # round or it is not evidence at all.
  python3 - "$WATCH_RUN_DIR" "$1" "$2" <<'EOF'
import json, os, sys
run, name, req = sys.argv[1], sys.argv[2], sys.argv[3]
p = lambda ext: os.path.join(run, "%s.duplex.%s" % (name, ext))
rnd = 0
keep = []
for line in open(p("meta")):
    if line.startswith("round="):
        rnd = int(line.split("=", 1)[1].strip() or 0)
    else:
        keep.append(line)
open(p("meta"), "w").writelines(keep + ["round=%d\n" % (rnd + 1)])
off = os.path.getsize(p("events.jsonl"))
open(p("sent-offset"), "w").write(str(off))
open(p("sent-journal"), "a").write(
    json.dumps({"ts": 0, "offset": off, "round": rnd + 1, "req": req}) + "\n")
EOF
}
ERR_FRAME='{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"provider returned 500 internal error"}}'
OK_FRAME='{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stopReason":"end_turn"}}'

omp_session e1a
cat "$FIXD/omp-authprobe-402.jsonl" >> "$WATCH_RUN_DIR/e1a.duplex.events.jsonl"
run_classify e1a
chk_eq "p1 the real 402 stream → STALLED-EXTERNAL 5, never DONE" 5 "$rc"
chk_contains "p1 the verdict routes to credentials" "fix credentials" "$out"
chk_contains "p1 and quotes the evidence it selected" "Insufficient Balance" "$out"

omp_session e1b
# the trimmed fixture is the engine's half of a round; the sender's half is its journal row,
# without which this stream carries no id anyone can correlate (see p7d below)
cut_round_req e1b ctl-fc4adce59f24
cat "$FIXD/omp-authprobe2-nokey.jsonl" >> "$WATCH_RUN_DIR/e1b.duplex.events.jsonl"
run_classify e1b
chk_eq "p2 a success:false AFTER success:true on the same id → STALLED-EXTERNAL 5" 5 "$rc"
chk_contains "p2 and quotes that rejection" "No API key" "$out"

omp_session e1c
ev e1c '{"id":"ctl-p3","type":"response","command":"prompt","success":true}'
ev e1c "$ERR_FRAME"
run_classify e1c
chk_eq "p3 an ordinary error frame → FAILED 2 (a turn failed, the engine is alive)" 2 "$rc"
chk_contains "p3 and the detail is the frame's own message" "500 internal error" "$out"
chk_not_contains "p3 never a credentials verdict" "STALLED-EXTERNAL" "$out"

omp_session e1d
ev e1d '{"id":"ctl-p4","type":"response","command":"prompt","success":true}'
ev e1d "$OK_FRAME"
run_classify e1d
chk_eq "p4 PAIRED GREEN: a clean round is still DONE 0" 0 "$rc"

# p5 — the round boundary is what stops an OLD credential failure from colouring a NEW one.
omp_session e1e
ev e1e '{"id":"ctl-old","type":"response","command":"prompt","success":false,"error":"No API key found for anthropic."}'
cut_round e1e
ev e1e '{"id":"ctl-new","type":"response","command":"prompt","success":true}'
ev e1e "$ERR_FRAME"
run_classify e1e
chk_eq "p5 last round's auth failure does not colour this round → FAILED 2" 2 "$rc"
chk_not_contains "p5 and the old credential text is not in the verdict" "No API key" "$out"
# p5b — and the boundary itself: LAST round ended in an error, THIS round has only its ack.
# Without the sent-offset window that stale frame is the newest evidence in the file and the
# fresh round is reported FAILED — a seat that was just handed new instructions.
omp_session e1e2
ev e1e2 '{"id":"ctl-oldx","type":"response","command":"prompt","success":true}'
ev e1e2 "$ERR_FRAME"
cut_round e1e2
ev e1e2 '{"id":"ctl-newx","type":"response","command":"prompt","success":true}'
run_classify e1e2
chk_eq "p5b last round's error frame is not this round's verdict" 0 "$rc"
chk_not_contains "p5b and its text never reaches this round's verdict" "500 internal error" "$out"

# p6 — recovery after an error inside the SAME round: reporting ERROR there kills a working seat
omp_session e1f
ev e1f '{"id":"ctl-p6","type":"response","command":"prompt","success":true}'
ev e1f "$ERR_FRAME"
ev e1f "$OK_FRAME"
run_classify e1f
chk_eq "p6 an error followed by a completed assistant turn is NOT terminal-failed" 0 "$rc"

# p7 — a PRIOR round's id answering late in this window is not this round's evidence
omp_session e1g
cut_round e1g
ev e1g '{"id":"ctl-new7","type":"response","command":"prompt","success":true}'
ev e1g '{"id":"ctl-old7","type":"response","command":"prompt","success":false,"error":"stale rejection from the previous round"}'
run_classify e1g
chk_eq "p7 a stale correlation id cannot fail this round" 0 "$rc"
chk_not_contains "p7 and its text never reaches a verdict" "stale rejection" "$out"

# p7b/p7c/p7d — the SENDER's request id, journalled beside the round's offset, is what decides
# whose response this is. Reachable order (v18.1.5: the RPC layer acks a prompt as soon as the
# background turn starts, while `abort_and_prompt` waits for the abort first): the OLD round's
# async setup can still fail, or still ack, INSIDE this round's window. Nothing about the
# stream's own order rules that out — only the id we actually sent does (review M1).
# p7b — old round's auth rejection lands BEFORE this round's ack
omp_session e1g2
cut_round_req e1g2 ctl-new7b
ev e1g2 '{"id":"ctl-old7b","type":"response","command":"prompt","success":false,"error":"No API key found for anthropic."}'
ev e1g2 '{"id":"ctl-new7b","type":"response","command":"prompt","success":true}'
run_classify e1g2
chk_eq "p7b a stale rejection arriving BEFORE this round's ack is still not ours" 0 "$rc"
chk_not_contains "p7b and no credential verdict is fabricated from it" "No API key" "$out"
# p7c — old true, new true, then THIS round's ordinary failure: FAILED, never auth-coloured
omp_session e1g3
ev e1g3 '{"id":"ctl-old7c","type":"response","command":"prompt","success":false,"error":"No API key found for anthropic."}'
cut_round_req e1g3 ctl-new7c
ev e1g3 '{"id":"ctl-old7c","type":"response","command":"prompt","success":true}'
ev e1g3 '{"id":"ctl-new7c","type":"response","command":"prompt","success":true}'
ev e1g3 '{"id":"ctl-new7c","type":"response","command":"prompt","success":false,"error":"provider returned 500 internal error"}'
run_classify e1g3
chk_eq "p7c this round's own rejection after a stale ack → FAILED 2" 2 "$rc"
chk_not_contains "p7c and last round's auth text never colours it" "No API key" "$out"
# p7d — the discriminating shape: a stale ack arriving AFTER ours, so "newest ack in the
# window" is the WRONG id and only the journalled request id gets this right.
omp_session e1g4
cut_round_req e1g4 ctl-new7d
ev e1g4 '{"id":"ctl-new7d","type":"response","command":"prompt","success":true}'
ev e1g4 '{"id":"ctl-old7d","type":"response","command":"prompt","success":true}'
ev e1g4 '{"id":"ctl-old7d","type":"response","command":"prompt","success":false,"error":"No API key found for anthropic."}'
run_classify e1g4
chk_eq "p7d a stale ack overtaking ours cannot hand the round to its own failure" 0 "$rc"
chk_not_contains "p7d and that failure text stays out of the verdict" "No API key" "$out"
# (p7d) — NO row for this round: the request id is UNKNOWN, so no `response` frame is this
# round's evidence at all. Guessing it from the stream (newest ack in the window — which is the
# STALE id in exactly this shape) handed the round to that stale id's own failure: an idle
# session reported as a credentials stall (review R2-M1). Assistant error frames need no id and
# are unaffected — p5 pins that half.
omp_session e1g5
cut_round e1g5
ev e1g5 '{"id":"ctl-new7e","type":"response","command":"prompt","success":true}'
ev e1g5 '{"id":"ctl-old7e","type":"response","command":"prompt","success":true}'
ev e1g5 '{"id":"ctl-old7e","type":"response","command":"prompt","success":false,"error":"No API key found for anthropic."}'
run_classify e1g5
chk_eq "(p7d) with no journalled round a stale response cannot fail this round" 0 "$rc"
chk_not_contains "(p7d) and no credentials verdict is invented without a correlation id" \
  "No API key" "$out"

# (p7f) — a pre-journal row (offset only, no round, no req) is a legacy fact, not this round's
omp_session e1g6
cut_round e1g6
python3 -c 'import json, sys
print(json.dumps({"ts": 0, "offset": int(open(sys.argv[1]).read().strip())}))' \
  "$WATCH_RUN_DIR/e1g6.duplex.sent-offset" >> "$WATCH_RUN_DIR/e1g6.duplex.sent-journal"
ev e1g6 '{"id":"ctl-new7f","type":"response","command":"prompt","success":true}'
ev e1g6 '{"id":"ctl-old7f","type":"response","command":"prompt","success":false,"error":"No API key found for anthropic."}'
run_classify e1g6
chk_eq "(p7f) a row with no round number proves nothing about this round" 0 "$rc"
chk_not_contains "(p7f) so its stale failure text stays out of the verdict" "No API key" "$out"

# (p7g) — two rounds at ONE offset (a steer whose engine produced nothing since the last one):
# the offset cannot tell them apart, the round number can, and the CURRENT round is the row
# that speaks. The paired arm proves the row is being read, not just ignored.
omp_session e1g7
cut_round_req e1g7 ctl-r1g
cut_round_req e1g7 ctl-r2g
ev e1g7 '{"id":"ctl-r1g","type":"response","command":"prompt","success":false,"error":"No API key found for anthropic."}'
ev e1g7 '{"id":"ctl-r2g","type":"response","command":"prompt","success":true}'
run_classify e1g7
chk_eq "(p7g) the previous round's row cannot speak for this one" 0 "$rc"
chk_not_contains "(p7g) and its rejection never becomes this round's verdict" "No API key" "$out"
ev e1g7 '{"id":"ctl-r2g","type":"response","command":"prompt","success":false,"error":"provider returned 500 internal error"}'
run_classify e1g7
chk_eq "(p7g) PAIRED GREEN: this round's OWN rejection still lands → FAILED 2" 2 "$rc"

# (p7e) — THE SENDER's half of the same discipline: a round that cannot be RECORDED is not
# opened. Best effort left the previous round's row as the newest one while a new round was
# already in flight, so a reader trusted a dead round's id (review R2-M2). The verb refuses
# locally instead: rc 3, nothing on the wire, no round rotation. A real permission failure on
# the journal, not a patched open().
omp_session e1x
: > "$WATCH_RUN_DIR/e1x.duplex.sent-journal"
chmod 0400 "$WATCH_RUN_DIR/e1x.duplex.sent-journal"
SEEN="$WATCH_RUN_DIR/e1x.duplex.events.jsonl.seen"
sx="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" send e1x --verb steer --text next 2>&1)"
sxrc=$?
chk_eq "(p7e) a steer whose round cannot be journalled refuses locally with rc 3" 3 "$sxrc"
chk_contains "(p7e) and the refusal names the verb it did not perform" "refusing to steer" "$sx"
chk_eq "(p7e) no frame carrying a message reached the fifo" "" \
  "$(grep '"message"' "$SEEN" 2>/dev/null)"
chk_eq "(p7e) and no row was appended for the round it refused to open" 0 \
  "$(wc -c < "$WATCH_RUN_DIR/e1x.duplex.sent-journal" | tr -d ' ')"
chk_eq "(p7e) the round counter did not move either" 0 \
  "$(grep -c '^round=' "$WATCH_RUN_DIR/e1x.duplex.meta")"
sy="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" send e1x --verb prompt --text goal 2>&1)"
syrc=$?
chk_eq "(p7e) goal delivery refuses on the same fact" 3 "$syrc"
chk_contains "(p7e) naming that verb in turn" "refusing to prompt" "$sy"
chk_eq "(p7e) still nothing but the get_state probe on the wire" "" \
  "$(grep '"message"' "$SEEN" 2>/dev/null)"
chmod 0600 "$WATCH_RUN_DIR/e1x.duplex.sent-journal"

# (p7h) — the SENDER's IDENTITY half of that same refusal. The replacement frame is what
# authorises a new attempt, so a frame that was never sent must leave the RUNNING attempt
# alone. The commit used to happen before the journal: a rc-3 refusal rotated the attempt
# anyway, and the worker nobody aborted kept producing evidence its own attempt now rejects
# while the watcher armed on it lost its publish right — for a frame that does not exist
# (cold review R3-M1). Real CLI, real fifo, a real 0400 journal.
id_attempt() { # $1 session — the ACTIVE record's attemptId, through the identity CLI only
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity show "$1" 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("attemptId", ""))'
}
id_token() { # $1 session — the arm-time token a watcher publishes against
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token "$1" 2>/dev/null
}
omp_session e1y
: > "$WATCH_RUN_DIR/e1y.duplex.sent-journal"
chmod 0400 "$WATCH_RUN_DIR/e1y.duplex.sent-journal"
SEENY="$WATCH_RUN_DIR/e1y.duplex.events.jsonl.seen"
: > "$SEENY"
A_Y="$(id_attempt e1y)"; T_Y="$(id_token e1y)"
chk_eq "(p7h) arrange: the session has an attempt to lose" 1 \
  "$([ -n "$A_Y" ] && echo 1 || echo 0)"
sz="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" send e1y --verb interrupt \
        --text "start over" --wait 1 2>&1)"
szrc=$?
chk_eq "(p7h) an interrupt whose round cannot be journalled refuses locally with rc 3" 3 "$szrc"
chk_contains "(p7h) and the refusal names the verb it did not perform" "refusing to interrupt" "$sz"
chk_eq "(p7h) not one byte of it reached the fifo" "" "$(cat "$SEENY")"
chk_eq "(p7h) DAMAGE ORACLE: the refused replacement did NOT rotate the attempt" \
  "$A_Y" "$(id_attempt e1y)"
chk_eq "(p7h) so the watcher armed on it can still publish this round's conclusion" 0 \
  "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish e1y --armed "$T_Y" \
       --round 0 --rc 2 --detail "old attempt still running" >/dev/null 2>&1; echo $?)"
chk_eq "(p7h) and the watcher armed before it keeps its publish right" "$T_Y" "$(id_token e1y)"
chk_eq "(p7h) the round counter did not move either" 0 \
  "$(grep -c '^round=' "$WATCH_RUN_DIR/e1y.duplex.meta")"

# (p7h2) PAIRED GREEN — with the journal writable the replacement really happens: frame on the
# wire, attempt rotated, round opened. (`send` waits for a correlated ack the minimal answerer
# does not speak, so its rc is the harness's, not the fix's; the facts below are the contract.)
chmod 0600 "$WATCH_RUN_DIR/e1y.duplex.sent-journal"
: > "$SEENY"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" send e1y --verb interrupt \
  --text "start over" --wait 1 >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do          # the answerer logs what it reads, asynchronously
  grep -q abort_and_prompt "$SEENY" 2>/dev/null && break
  /bin/sleep 0.2
done
chk_eq "(p7h2) the replacement frame goes out" 1 "$(grep -c abort_and_prompt "$SEENY")"
chk_eq "(p7h2) and THEN the attempt rotates" 1 \
  "$([ -n "$(id_attempt e1y)" ] && [ "$(id_attempt e1y)" != "$A_Y" ] && echo 1 || echo 0)"
chk_eq "(p7h2) fencing the watcher armed on the previous attempt" 1 \
  "$([ "$(id_token e1y)" != "$T_Y" ] && echo 1 || echo 0)"
chk_eq "(p7h2) with the round it opened recorded" 1 \
  "$(grep -c '^round=1$' "$WATCH_RUN_DIR/e1y.duplex.meta")"

# (p7i) — the PROJECTOR's half of the round fence: the round must come from the SAME sample as
# the window it selects evidence in. get_state is a round trip that can take seconds and holds
# no lock while it waits, so a legal steer can complete inside it. The projector then held a NEW
# window with the OLD round's request id: this round's own rejection was skipped and a
# just-failed engine read DONE (cold review R3-M2). The answerer below performs that steer —
# journal row, round bump, sent-offset, this round's frames — BEFORE it answers, so the
# interleaving is deterministic instead of hoped for.
omp_answer_midflight_steer() { # $1 session  $2 request id the mid-flight steer opens with
  python3 - "$WATCH_RUN_DIR" "$1" "$2" <<'EOF' &
import json, os, sys, time
run, name, req = sys.argv[1], sys.argv[2], sys.argv[3]
p = lambda ext: os.path.join(run, "%s.duplex.%s" % (name, ext))
deadline = time.time() + 120
while time.time() < deadline:
    try:
        with open(p("in")) as fh:            # blocks for a writer, exactly like omp_answer
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                with open(p("events.jsonl") + ".seen", "a") as sn:
                    sn.write(line + "\n")
                if msg.get("type") not in ("get_state", "get-state"):
                    continue
                # the steer, in commit_round_state's own order, while the caller waits
                rnd, keep = 0, []
                for ln in open(p("meta")):
                    if ln.startswith("round="):
                        rnd = int(ln.split("=", 1)[1].strip() or 0)
                    else:
                        keep.append(ln)
                off = os.path.getsize(p("events.jsonl"))
                open(p("sent-journal"), "a").write(json.dumps(
                    {"ts": 0, "offset": off, "round": rnd + 1, "req": req}) + "\n")
                open(p("meta"), "w").writelines(keep + ["round=%d\n" % (rnd + 1)])
                open(p("sent-offset"), "w").write(str(off))
                with open(p("events.jsonl"), "a") as ev:
                    for ok in (True, False):
                        frame = {"id": req, "type": "response", "command": "steer",
                                 "success": ok}
                        if not ok:
                            frame["error"] = "provider returned 500 internal error"
                        ev.write(json.dumps(frame) + "\n")
                    ev.write(json.dumps({
                        "id": msg.get("id"), "type": "response", "command": "get_state",
                        "success": True,
                        "data": {"isStreaming": False, "isCompacting": False,
                                 "sessionId": "fixture", "messageCount": 2,
                                 "queuedMessageCount": 0}}) + "\n")
                sys.exit(0)
    except OSError:
        time.sleep(0.05)
EOF
  ANSWERERS="$ANSWERERS $!"
}
seed_session e1z omp "$WT"
omp_answer_midflight_steer e1z ctl-r2z
cut_round_req e1z ctl-r1z
ev e1z '{"id":"ctl-r1z","type":"response","command":"prompt","success":true}'
run_classify e1z
chk_eq "(p7i) a steer completing during get_state cannot hide THIS round's failure → FAILED 2" \
  2 "$rc"
chk_contains "(p7i) and the verdict quotes the new round's own rejection" \
  "500 internal error" "$out"
chk_eq "(p7i) arrange: the steer really did rotate the round on disk" 1 \
  "$(grep -c '^round=2$' "$WATCH_RUN_DIR/e1z.duplex.meta")"

# (p7i2) PAIRED GREEN — the identical payload with that steer already settled before classify:
# the verdict is the one this suite already asserted, so the fix moved the mixed-generation
# sample and nothing else.
omp_session e1z2
cut_round_req e1z2 ctl-r1z2
ev e1z2 '{"id":"ctl-r1z2","type":"response","command":"prompt","success":true}'
cut_round_req e1z2 ctl-r2z2
ev e1z2 '{"id":"ctl-r2z2","type":"response","command":"steer","success":true}'
ev e1z2 '{"id":"ctl-r2z2","type":"response","command":"steer","success":false,"error":"provider returned 500 internal error"}'
run_classify e1z2
chk_eq "(p7i2) the same payload with the steer already settled → FAILED 2" 2 "$rc"
chk_contains "(p7i2) on the same evidence" "500 internal error" "$out"

# p11 — streaming outranks every piece of error evidence in the window (H2: streaming /
# retrying → RUNNING, always). A live turn must never be concluded from a frame that is
# already in the file.
omp_session e1k stream
ev e1k '{"id":"ctl-p11","type":"response","command":"prompt","success":true}'
ev e1k "$ERR_FRAME"
run_classify e1k
chk_eq "p11 an error frame under isStreaming=true is still RUNNING 10" 10 "$rc"
chk_not_contains "p11 and no failure is announced mid-stream" "FAILED" "$out"

omp_session e1h
ev e1h '{"id":"ctl-p8","type":"response","command":"prompt","success":true}'
ev e1h "$ERR_FRAME"
ev e1h '{"type":"auto_retry_start","attempt":1}'
run_classify e1h
chk_eq "p8 an auto-retry in flight is RUNNING 10, never a failure" 10 "$rc"

omp_session e1i
ev e1i '{"id":"ctl-p9","type":"response","command":"prompt","success":true}'
ev e1i '{"type":"auto_retry_start","attempt":1}'
ev e1i '{"type":"auto_retry_end","success":false,"attempt":1,"finalError":"provider returned 500 internal error after 3 attempts"}'
run_classify e1i
chk_eq "p9 auto_retry_end success:false → FAILED 2" 2 "$rc"
chk_contains "p9 and the finalError is the evidence" "after 3 attempts" "$out"
omp_session e1i2
ev e1i2 '{"id":"ctl-p9b","type":"response","command":"prompt","success":true}'
ev e1i2 "$ERR_FRAME"
ev e1i2 '{"type":"auto_retry_end","success":true,"attempt":1}'
run_classify e1i2
chk_eq "p9 PAIRED GREEN: a retry that LANDED clears the error" 0 "$rc"

# p10 — an ask that arrived AFTER the error is what the engine is waiting on now
omp_session e1j
ev e1j '{"id":"ctl-p10","type":"response","command":"prompt","success":true}'
ev e1j "$ERR_FRAME"
ev e1j '{"type":"extension_ui_request","id":"ui-q1","method":"confirm","title":"Proceed?"}'
run_classify e1j
chk_eq "p10 a pending ask after the error reads WAITING-INPUT 4" 4 "$rc"

{ kill $ANSWERERS; wait $ANSWERERS; } 2>/dev/null
unset FAKE_TMUX_HASSESSION

{ kill "$QPID" "$TPID"; wait "$QPID" "$TPID"; } 2>/dev/null
rm -rf "$SANDBOX"
summary
