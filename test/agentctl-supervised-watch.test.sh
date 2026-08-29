#!/usr/bin/env bash
# supervised watch — the sensing loop lives in tmux, `agentctl watch` is a dumb waiter.
#
# Threat this exists for (downstream seat, production): the host reaps orchestrator-side
# background tasks (2026-08-08: ≥6 kills in 40min across two parallel sessions) while the tmux
# worker rides it out untouched. Pre-supervision that killed the SENSING loop, and every
# non-DONE conclusion it had computed died unpublished — the re-arm round became routine cost.
#
# Every stimulus below enters through the PUBLIC CLI (`agentctl watch/steer/stop`, `duplexctl
# identity …`), a REAL classify exit, or an OS signal. Nothing here hand-writes a terminal record
# and then reads it back: a reader fed by a writer that is really the same fixture cannot catch a
# common-mode error, so the records under test are always produced by the shipped publisher.
#
# Harness: a PROCESS-RUNNING fake tmux (new-session really runs the pane command, refuses a
# duplicate name like the real one, kill-session kills the tree) plus hand-seeded session state
# for the classify-driven classes — same stance as duplex-verdict-gaps. Real `sleep`: the timing
# of "supervisor still sensing" vs "waiter polled again" is part of what is under test.
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

AGENTCTL="$AW_DIR/agentctl"
DUPLEXCTL="$AW_DIR/duplexctl.py"

# ── harness ───────────────────────────────────────────────────────────────────────────
sw_sandbox() {
  sandbox_new
  rm -f "$BIN/sleep"                     # real sleep: the poll cadence IS part of the contract
  export FAKE_TMUX_STATE="$SANDBOX/tmux-state"
  mkdir -p "$FAKE_TMUX_STATE"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
name=""; cwd=""; cmd=""
while [ "$#" -gt 0 ]; do case "$1" in
  -s|-t) name="$2"; shift 2;;
  -c) cwd="$2"; shift 2;;
  -d|-p) shift;;
  *) cmd="$1"; shift;;
esac; done
name="${name#=}"; name="${name%:}"
alive() { # $1 name
  local p; p="$(cat "$FAKE_TMUX_STATE/$1.pid" 2>/dev/null)" || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
killtree() { # what real tmux + agentctl's reap do to a pane: the WHOLE tree, not just the child
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done
  kill -9 "$p" 2>/dev/null
}
case "$sub" in
  new-session)
    # real tmux refuses a duplicate session name server-side, ATOMICALLY. mkdir is this
    # harness's equivalent claim: a check-then-write would let two racing waiters both
    # "win" and would make the singleton property untestable.
    if ! mkdir "$FAKE_TMUX_STATE/$name.lock" 2>/dev/null; then
      if [ -f "$FAKE_TMUX_STATE/$name.pid" ] && ! alive "$name"; then :   # dead: reclaim
      else echo "duplicate session: $name" >&2; exit 1; fi
    fi
    ( cd "${cwd:-/}" && exec bash -c "$cmd" ) >/dev/null 2>&1 &
    echo $! > "$FAKE_TMUX_STATE/$name.pid"
    printf '%s\n' "$name" >> "$FAKE_TMUX_STATE/new-session.log"
    printf '%s\t%s\n' "$name" "$cmd" >> "$FAKE_TMUX_STATE/new-session.cmd.log"
    exit 0 ;;
  has-session) alive "$name" ;;
  kill-session)
    p="$(cat "$FAKE_TMUX_STATE/$name.pid" 2>/dev/null)"
    [ -n "$p" ] && killtree "$p"
    rm -f "$FAKE_TMUX_STATE/$name.pid"; rmdir "$FAKE_TMUX_STATE/$name.lock" 2>/dev/null
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BIN/tmux"
  WT="$SANDBOX/wt"; mkdir -p "$WT"
  SLEEPERS=""
  export AGENT_WATCH_POLL_SECS=1
}

sw_clean() {
  local p n
  for p in $SLEEPERS; do kill -9 "$p" 2>/dev/null; done
  for n in "$FAKE_TMUX_STATE"/*.pid; do
    [ -f "$n" ] || continue
    p="$(cat "$n")"; pkill -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null
  done
  sandbox_clean
}

# A session tmux believes is alive: classify's liveness probe must pass, and `stop`/`kill-session`
# must have something real to kill. Its pid is a sleeper we own, never the test shell's.
seed() { # $1 name  [$2 pane_pid]
  /bin/sleep 600 & local sl=$!
  disown "$sl" 2>/dev/null || true
  SLEEPERS="$SLEEPERS $sl"
  echo "$sl" > "$FAKE_TMUX_STATE/$1.pid"
  { printf 'engine=claude\ncwd=%s\nround=1\n' "$WT"
    [ -n "${2:-}" ] && printf 'pane_pid=%s\n' "$2"; } > "$WATCH_RUN_DIR/$1.duplex.meta"
  : > "$WATCH_RUN_DIR/$1.duplex.round-started"
  : > "$WATCH_RUN_DIR/$1.duplex.events.jsonl"
  : > "$WATCH_RUN_DIR/$1.duplex.stderr.log"
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity start "$1" >/dev/null 2>&1
}

ev() { printf '%s\n' "$2" >> "$WATCH_RUN_DIR/$1.duplex.events.jsonl"; }
running() { ev "$1" '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'; }

await() { # $1 label-less predicate as a command string, $2 tries (0.1s each)
  local i=0
  while [ "$i" -lt "${2:-100}" ]; do
    eval "$1" && return 0
    /bin/sleep 0.1; i=$((i+1))
  done
  return 1
}

watch_bg() { # $1 session  $2 outfile  [$3.. env assignments already exported by caller]
  bash "$AGENTCTL" watch "$1" > "$2" 2>&1 &
  WPID_BG=$!
}

lease_pid() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' \
                "$WATCH_RUN_DIR/$1.watch.super.json" 2>/dev/null; }
spawn_count() { grep -c "^$1-watchd\$" "$FAKE_TMUX_STATE/new-session.log" 2>/dev/null || echo 0; }
record_class() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("class",""))' \
                   "$WATCH_RUN_DIR/$1.terminal.json" 2>/dev/null; }

# Drive one class to a published record with NO waiter attached at publish time: arm a waiter on a
# RUNNING fixture, TERM it (the production failure mode), and only then make classify terminal.
# That is the window the whole workstream exists for.
kill_waiter_then() { # $1 session  $2 shell snippet that makes classify terminal
  watch_bg "$1" "$SANDBOX/$1.w1.log"
  await "[ -s '$WATCH_RUN_DIR/$1.watch.super.json' ]" 100 || return 1
  kill -TERM "$WPID_BG" 2>/dev/null
  wait "$WPID_BG" 2>/dev/null; W1RC=$?
  eval "$2"
  await "[ -s '$WATCH_RUN_DIR/$1.terminal.json' ]" 200 || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M15/M09/M06: the canonical command really supervises; all eight classes survive =="
sw_sandbox

# fixtures: (class, exit, snippet that turns a RUNNING seeded session into that class)
run_class() { # $1 session  $2 expected-exit  $3 make-terminal snippet  $4 needle
  seed "$1" 70000
  running "$1"
  export AGENT_WATCH_MAX_POLLS=1000
  kill_waiter_then "$1" "$3" || { _record "M09 $1 fixture reached a published record" 0 "timeout"; return; }
  chk_eq "M09 $1: the TERM'd waiter really died (143)" 143 "$W1RC"
  chk_eq "M09 $1: the supervisor published the class, not the waiter" \
    "$(python3 -c 'import json,sys;print({0:"DONE",2:"FAILED",4:"WAITING-INPUT",5:"STALLED-EXTERNAL",6:"IDLE-NO-DELIVERABLE",7:"WATCH-TIMEOUT",8:"ENGINE-SILENT",11:"STALLED-STREAM"}[int(sys.argv[1])])' "$2")" \
    "$(record_class "$1")"
  before="$(spawn_count "$1")"
  out="$(bash "$AGENTCTL" watch "$1" 2>&1)"; rc=$?
  chk_eq "M09 $1: a brand-new waiter recovers exit $2 from the record" "$2" "$rc"
  chk_contains "M09 $1: and reproduces the class line" "$4" "$out"
  chk_eq "M09 $1: recovery re-derived nothing (no second supervisor)" "$before" "$(spawn_count "$1")"
}

WTB="$WT/blocked"; mkdir -p "$WTB"
run_class swDONE 0 'printf "0\n" > "$WATCH_RUN_DIR/swDONE.duplex.rc"' "DONE"
run_class swFAIL 2 'printf "3\n" > "$WATCH_RUN_DIR/swFAIL.duplex.rc"' "FAILED"
run_class swWAIT 4 'printf "need a decision\n" > "$WT/BLOCKED.md"' "WAITING-INPUT"
rm -f "$WT/BLOCKED.md"
run_class swQUOTA 5 'printf "insufficient_quota\n" >> "$WATCH_RUN_DIR/swQUOTA.duplex.stderr.log"; printf "1\n" > "$WATCH_RUN_DIR/swQUOTA.duplex.rc"' "STALLED-EXTERNAL"
run_class swIDLE 6 'printf "deliverable=nope-*.md\n" >> "$WATCH_RUN_DIR/swIDLE.duplex.meta"; printf "0\n" > "$WATCH_RUN_DIR/swIDLE.duplex.rc"' "IDLE-NO-DELIVERABLE"
run_class swSILENT 8 'printf "0" > "$WATCH_RUN_DIR/swSILENT.duplex.sent-offset"; : > "$WATCH_RUN_DIR/swSILENT.duplex.events.jsonl"; export AGENT_WATCH_SILENT_POLLS=2' "ENGINE-SILENT"
unset AGENT_WATCH_SILENT_POLLS

# 11 STALLED-STREAM needs the real stall probe: a wedged provider tree under a fake ps, reached
# through the supervisor's own classify (PATH is forwarded into the pane, so the probe applies).
PSBIN="$SANDBOX/psbin"; mkdir -p "$PSBIN"
# The fixture is selected by a FILE, not by an env var: the supervisor runs in its own pane and
# inherits only what the pane command spells out, so an env-driven fake would silently never
# reach the process actually doing the classifying (probed: it did not).
cat > "$PSBIN/ps" <<'FAKEPS'
#!/bin/sh
fix="$(dirname "$0")/../ps-fixture.txt"
if [ -f "$fix" ] && [ "${3:-}" != "-p" ]; then cat "$fix"; exit 0; fi
exec /bin/ps "$@"
FAKEPS
chmod +x "$PSBIN/ps"
cat > "$SANDBOX/ps-wedged.txt" <<'PS'
70000     1 03:25:01
70001 70000 03:25:00
70002 70001 03:25:00
70003 70002 1-02:00:00
PS
seed swSTALL 70000
running swSTALL
export AGENT_WATCH_MAX_POLLS=1000
OLDPATH="$PATH"; export PATH="$PSBIN:$PATH"
if kill_waiter_then swSTALL 'cp "$SANDBOX/ps-wedged.txt" "$SANDBOX/ps-fixture.txt"; python3 -c "import os,sys,time; os.utime(sys.argv[1],(time.time()-1200,)*2)" "$WATCH_RUN_DIR/swSTALL.duplex.events.jsonl"'; then
  chk_eq "M09 swSTALL: the TERM'd waiter really died (143)" 143 "$W1RC"
  chk_eq "M09 swSTALL: STALLED-STREAM persisted by the supervisor" "STALLED-STREAM" "$(record_class swSTALL)"
  before="$(spawn_count swSTALL)"
  out="$(bash "$AGENTCTL" watch swSTALL 2>&1)"; rc=$?
  chk_eq "M09 swSTALL: a brand-new waiter recovers exit 11" 11 "$rc"
  chk_contains "M09 swSTALL: and reproduces the class line" "STALLED-STREAM" "$out"
  chk_eq "M09 swSTALL: recovery re-derived nothing" "$before" "$(spawn_count swSTALL)"
else
  _record "M09 swSTALL: the supervisor published a STALLED-STREAM record" 0 "no record appeared"
fi
rm -f "$SANDBOX/ps-fixture.txt"; export PATH="$OLDPATH"

# 7 WATCH-TIMEOUT is the supervisor's OWN budget running out — no fixture can inject it
seed swTMO 70000
running swTMO
export AGENT_WATCH_MAX_POLLS=3
watch_bg swTMO "$SANDBOX/swTMO.w1.log"
await "[ -s '$WATCH_RUN_DIR/swTMO.watch.super.json' ]" 100
kill -TERM "$WPID_BG" 2>/dev/null; wait "$WPID_BG" 2>/dev/null
chk_eq "M09 swTMO: budget exhaustion is persisted, not lost with the waiter" 1 \
  "$(await "[ -s '$WATCH_RUN_DIR/swTMO.terminal.json' ]" 200 && echo 1 || echo 0)"
chk_eq "M09 swTMO: class recorded" "WATCH-TIMEOUT" "$(record_class swTMO)"
before="$(spawn_count swTMO)"
out="$(bash "$AGENTCTL" watch swTMO 2>&1)"; rc=$?
chk_eq "M09 swTMO: a brand-new waiter recovers exit 7" 7 "$rc"
chk_contains "M09 swTMO: and reproduces the class line" "WATCH TIMEOUT" "$out"
chk_eq "M09 swTMO: recovery re-derived nothing" "$before" "$(spawn_count swTMO)"

# M15 — the ACTIVATION surface: the canonical command (no flags) is what supervises. If the
# supervisor were an opt-in nobody calls, the log below would be empty and every recovery above
# would have been the old in-process loop.
chk_eq 'M15 DAMAGE ORACLE: the canonical "agentctl watch" established a tmux supervisor per session' 1 \
  "$([ "$(spawn_count swDONE)" -ge 1 ] && echo 1 || echo 0)"
chk_contains "M15 the supervisor pane really runs the sensing verb" "watch-daemon" \
  "$(grep "^swDONE-watchd" "$FAKE_TMUX_STATE/new-session.cmd.log")"
seed swACT 70000; running swACT
export AGENT_WATCH_MAX_POLLS=1000
watch_bg swACT "$SANDBOX/swACT.log"
await "[ -s '$WATCH_RUN_DIR/swACT.watch.super.json' ]" 100
/bin/sleep 1
chk_contains "M15 the canonical waiter names the tmux session sensing for it" "swACT-watchd" \
  "$(cat "$SANDBOX/swACT.log")"
chk_contains "M15 and says it is only reading the fenced record" "only reads the fenced" \
  "$(cat "$SANDBOX/swACT.log")"
kill -TERM "$WPID_BG" 2>/dev/null; wait "$WPID_BG" 2>/dev/null
chk_contains "M15 the published capability contract says supervised" "supervised" \
  "$(bash "$AGENTCTL" capabilities 2>&1)"

# M06 — a same-name NEW attempt must not ADOPT attempt A's conclusion, for ANY of the classes.
# `identity replace` is the public rotation; A's records stay exactly where they are. The oracle
# is the canonical reader's adoption decision, not the exit code: B legitimately RE-DERIVES the
# same class from the same live facts (the rc file still says 3), and calling that a replay would
# make this test pass for the wrong reason.
for s in swDONE swFAIL swWAIT swQUOTA swIDLE swSILENT swSTALL swTMO; do
  [ -s "$WATCH_RUN_DIR/$s.terminal.json" ] || cp "$WATCH_RUN_DIR/$s.terminal.consumed.json" \
     "$WATCH_RUN_DIR/$s.terminal.json" 2>/dev/null || true
done
m6_adopted=0; m6_unfenced=0; m6_seen=0
for s in swDONE swFAIL swWAIT swQUOTA swIDLE swSILENT swSTALL swTMO; do
  [ -s "$WATCH_RUN_DIR/$s.terminal.json" ] || { echo "    (M06 $s: no record of either kind)"; continue; }
  m6_seen=$((m6_seen+1))
  python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity replace "$s" >/dev/null 2>&1
  out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state "$s" --arm 2>&1)"; rc=$?
  [ "$rc" = 13 ] || { m6_adopted=$((m6_adopted+1)); echo "    (M06 $s: attempt B adopted A's record, rc=$rc)"; }
  case "$out" in *STALE-ATTEMPT*) ;; *) m6_unfenced=$((m6_unfenced+1)); echo "    (M06 $s: refusal did not name the attempt fence: $out)";; esac
done
chk_eq "M06 arrange: every class left a record for attempt B to trip over" 8 "$m6_seen"
chk_eq "M06 DAMAGE ORACLE: attempt B adopts NONE of attempt A's conclusions" 0 "$m6_adopted"
chk_eq "M06 and every refusal names the attempt fence" 0 "$m6_unfenced"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M01/M02: a killed waiter loses nothing; the conclusion is produced once =="
sw_sandbox
seed m1 70000; running m1
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m1 "$SANDBOX/m1.w1.log"
await "[ -s '$WATCH_RUN_DIR/m1.watch.super.json' ]" 100
SUPPID="$(lease_pid m1)"
kill -TERM "$WPID_BG"; wait "$WPID_BG" 2>/dev/null; w1rc=$?
chk_eq "M01 the original waiter exited on TERM (143)" 143 "$w1rc"
chk_eq "M01 the supervisor is untouched by the waiter's death" 1 \
  "$(kill -0 "$SUPPID" 2>/dev/null && echo 1 || echo 0)"
chk_eq "M01 the killed waiter left an attributable tombstone" 1 \
  "$([ -s "$WATCH_RUN_DIR/m1.watch.tombstone.jsonl" ] && echo 1 || echo 0)"
printf '0\n' > "$WATCH_RUN_DIR/m1.duplex.rc"          # real classify turns terminal
await "[ -s '$WATCH_RUN_DIR/m1.terminal.json' ]" 200
spawns="$(spawn_count m1)"
evsize="$(wc -c < "$WATCH_RUN_DIR/m1.duplex.events.jsonl" | tr -d ' ')"
out="$(bash "$AGENTCTL" watch m1 2>&1)"; rc=$?
chk_eq "M01 the replacement waiter returns the same class + exit" 0 "$rc"
chk_contains "M01 and prints the supervisor's own verdict line" "DONE" "$out"
chk_eq "M01 DAMAGE ORACLE: it did NOT restart classification (no new supervisor)" "$spawns" "$(spawn_count m1)"
chk_eq "M01 and produced no new engine traffic" "$evsize" \
  "$(wc -c < "$WATCH_RUN_DIR/m1.duplex.events.jsonl" | tr -d ' ')"

# M02 — the conclusion exists but no waiter has reported it yet: kill and re-invoke repeatedly.
# One record, one publish sequence, same answer every time.
seq_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' \
             "$WATCH_RUN_DIR/m1.terminal.json"; }
seed m2 70000; running m2
watch_bg m2 "$SANDBOX/m2.w1.log"
await "[ -s '$WATCH_RUN_DIR/m2.watch.super.json' ]" 100
kill -TERM "$WPID_BG"; wait "$WPID_BG" 2>/dev/null
printf '0\n' > "$WATCH_RUN_DIR/m2.duplex.rc"
await "[ -s '$WATCH_RUN_DIR/m2.terminal.json' ]" 200
m2seq="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' "$WATCH_RUN_DIR/m2.terminal.json")"
r1="$(bash "$AGENTCTL" watch m2 >/dev/null 2>&1; echo $?)"
r2="$(bash "$AGENTCTL" watch m2 >/dev/null 2>&1; echo $?)"
chk_eq "M02 first re-invocation reports the conclusion" 0 "$r1"
chk_eq "M02 second re-invocation reports the SAME conclusion" 0 "$r2"
chk_eq "M02 DAMAGE ORACLE: no second classification side effect (publish seq unmoved)" "$m2seq" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' "$WATCH_RUN_DIR/m2.terminal.json")"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M03/M04/M05: dead vs alive vs concluded-then-dead =="
sw_sandbox

# M03 — the worker is fine, the SUPERVISOR is killed, and there is no conclusion.
seed m3 70000; running m3
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m3 "$SANDBOX/m3.w.log"
await "[ -s '$WATCH_RUN_DIR/m3.watch.super.json' ]" 100
kill -9 "$(lease_pid m3)" 2>/dev/null
t0=$(date +%s)
wait "$WPID_BG" 2>/dev/null; rc=$?
el=$(( $(date +%s) - t0 ))
out="$(cat "$SANDBOX/m3.w.log")"
chk_eq "M03 DAMAGE ORACLE: a dead supervisor with no conclusion is typed 12, never 0" 12 "$rc"
chk_contains "M03 the class is named" "SUPERVISOR-LOST" "$out"
chk_contains "M03 the reason distinguishes death from undecidability" "reason=dead" "$out"
chk_not_contains "M03 a lost supervisor is never DONE" "=== [m3] DONE" "$out"
chk_eq "M03 and it returned bounded (< 60s), never silently waited" 1 "$([ "$el" -lt 60 ] && echo 1 || echo 0)"
chk_eq "M03 the worker session was never touched" 1 \
  "$(tmux has-session -t "=m3" 2>/dev/null && echo 1 || echo 0)"

# M04 PAIRED GREEN — supervisor alive, classify honestly RUNNING, waiter across several cycles.
seed m4 70000; running m4
watch_bg m4 "$SANDBOX/m4.w.log"
await "[ -s '$WATCH_RUN_DIR/m4.watch.super.json' ]" 100
/bin/sleep 4                                   # ≥3 waiter poll cycles at POLL=1
chk_eq "M04 DAMAGE ORACLE: a live supervisor is never reported dead" 1 \
  "$(kill -0 "$WPID_BG" 2>/dev/null && echo 1 || echo 0)"
out="$(cat "$SANDBOX/m4.w.log")"
chk_not_contains "M04 no SUPERVISOR-LOST while it is sensing" "SUPERVISOR-LOST" "$out"
chk_not_contains "M04 no terminal verdict invented while RUNNING" "EXIT=" "$out"
chk_eq "M04 and RUNNING produced no terminal record" 0 \
  "$([ -e "$WATCH_RUN_DIR/m4.terminal.json" ] && echo 1 || echo 0)"
printf '0\n' > "$WATCH_RUN_DIR/m4.duplex.rc"   # the real terminal still arrives
wait "$WPID_BG" 2>/dev/null; rc=$?
chk_eq "M04 PAIRED GREEN: the waiter that did not panic still gets the real class" 0 "$rc"

# M05 — publish and death are visible at the same instant: the fenced record wins.
seed m5 70000
printf '0\n' > "$WATCH_RUN_DIR/m5.duplex.rc"   # terminal on the FIRST poll: publish, then exit
export AGENT_WATCH_MAX_POLLS=1000
out="$(bash "$AGENTCTL" watch m5 2>&1)"; rc=$?
chk_eq "M05 DAMAGE ORACLE: 'supervisor exited' never overrides its own conclusion" 0 "$rc"
chk_contains "M05 the conclusion is the one the supervisor published" "DONE" "$out"
chk_not_contains "M05 and it is not reported as a lost supervisor" "SUPERVISOR-LOST" "$out"
chk_eq "M05 arrange: the supervisor really is gone by now" 0 \
  "$(await "! kill -0 $(lease_pid m5) 2>/dev/null" 100 && echo 0 || echo 1)"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M07/M08: incarnation and round do not leak across a resume or a steer =="
sw_sandbox

# M07 — same attempt, new process incarnation (the supported resume transition). The record the
# previous incarnation published must not be adopted, and must not read as a death either.
seed m7 70000
printf '0\n' > "$WATCH_RUN_DIR/m7.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
rc0="$(bash "$AGENTCTL" watch m7 >/dev/null 2>&1; echo $?)"
chk_eq "M07 arrange: incarnation A published a real DONE record" 0 "$rc0"
inc_a="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["processIncarnation"])' \
          "$WATCH_RUN_DIR/m7.identity.d/active.json")"
printf 'pane_pid=%s\npane_lstart=%s\n' "$$" "resumed-at-a-different-time" >> "$WATCH_RUN_DIR/m7.duplex.meta"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity resume m7 >/dev/null 2>&1
inc_b="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["processIncarnation"])' \
          "$WATCH_RUN_DIR/m7.identity.d/active.json")"
chk_eq "M07 arrange: the attempt is unchanged but the incarnation rotated" 1 \
  "$([ "$inc_a" != "$inc_b" ] && echo 1 || echo 0)"
export AGENT_WATCH_MAX_POLLS=1 AGENTCTL_SUPERVISOR_ARM_TRIES=5
out="$(bash "$AGENTCTL" watch m7 2>&1)"; rc=$?
chk_eq "M07 DAMAGE ORACLE: the old incarnation's DONE is not adopted after resume" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_not_contains "M07 no false DONE across the incarnation boundary" "=== [m7] DONE" "$out"
unset AGENTCTL_SUPERVISOR_ARM_TRIES

# M08 — a plain steer opens the NEXT round. The previous round's conclusion must not be replayed,
# and a conclusion computed for the previous round must be refused at publish (the round fence).
seed m8 70000
printf '0\n' > "$WATCH_RUN_DIR/m8.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
bash "$AGENTCTL" watch m8 >/dev/null 2>&1
chk_eq "M08 arrange: round 1 concluded DONE and the record is on disk" 1 \
  "$([ -s "$WATCH_RUN_DIR/m8.terminal.json" ] && echo 1 || echo 0)"
armed="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token m8)"
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/m8.duplex.meta"; rm -f "$WATCH_RUN_DIR/m8.duplex.meta.bak"
rm -f "$WATCH_RUN_DIR/m8.terminal.json"       # what `agentctl steer` does when it opens a round
pout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish m8 --armed "$armed" \
        --rc 0 --round 1 --detail "late conclusion about round 1" 2>&1)"; prc=$?
chk_eq "M08 DAMAGE ORACLE: a conclusion computed for the previous round is refused" 2 "$prc"
chk_contains "M08 the refusal names the round fence" "STALE-ROUND" "$pout"
chk_eq "M08 and nothing was written" 0 \
  "$([ -e "$WATCH_RUN_DIR/m8.terminal.json" ] && echo 1 || echo 0)"
pout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish m8 --armed "$armed" \
        --rc 0 --round 2 --detail "conclusion about round 2" 2>&1)"; prc=$?
chk_eq "M08 PAIRED GREEN: the CURRENT round's conclusion publishes" 0 "$prc"
chk_eq "M08 PAIRED GREEN: and a waiter reports it" 0 \
  "$(bash "$AGENTCTL" watch m8 >/dev/null 2>&1; echo $?)"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M10: RUNNING is not a terminal state and never becomes a record =="
sw_sandbox
seed m10 70000; running m10
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m10 "$SANDBOX/m10.a.log"
await "[ -s '$WATCH_RUN_DIR/m10.watch.super.json' ]" 100
/bin/sleep 2
kill -TERM "$WPID_BG"; wait "$WPID_BG" 2>/dev/null
chk_eq "M10 DAMAGE ORACLE: repeated real RUNNING never produces a terminal record" 0 \
  "$([ -e "$WATCH_RUN_DIR/m10.terminal.json" ] && echo 1 || echo 0)"
watch_bg m10 "$SANDBOX/m10.b.log"
/bin/sleep 2
chk_eq "M10 the restarted waiter keeps waiting instead of reporting" 1 \
  "$(kill -0 "$WPID_BG" 2>/dev/null && echo 1 || echo 0)"
chk_not_contains "M10 it reported no stale class" "EXIT=" "$(cat "$SANDBOX/m10.b.log")"
kill -TERM "$WPID_BG" 2>/dev/null; wait "$WPID_BG" 2>/dev/null
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M11/M12: a publish that did not land, and a record that cannot be trusted =="
sw_sandbox

# M11 — the publisher is SIGKILLed between "temp file complete" and rename (the shipped test
# seam), inside the real supervisor. Debris must never be adopted and must not read as DONE.
seed m11 70000
printf '0\n' > "$WATCH_RUN_DIR/m11.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000 AGENTCTL_PUBLISH_BARRIER="$SANDBOX/barrier"
out="$(bash "$AGENTCTL" watch m11 2>&1)"; rc=$?
unset AGENTCTL_PUBLISH_BARRIER
chk_eq "M11 arrange: the interruption window was really reached" 1 \
  "$([ -s "$SANDBOX/barrier" ] && echo 1 || echo 0)"
chk_eq "M11 DAMAGE ORACLE: an interrupted publish never becomes a conclusion" 12 "$rc"
chk_not_contains "M11 no DONE from publish debris" "=== [m11] DONE" "$out"
chk_eq "M11 no terminal record exists" 0 \
  "$([ -e "$WATCH_RUN_DIR/m11.terminal.json" ] && echo 1 || echo 0)"

# M11b — the publish target cannot be written at all: the supervisor must say so, publish nothing.
seed m11b 70000
printf '0\n' > "$WATCH_RUN_DIR/m11b.duplex.rc"
chmod 500 "$WATCH_RUN_DIR"
out="$(bash "$AGENTCTL" watch m11b 2>&1)"; rc=$?
chmod 700 "$WATCH_RUN_DIR"
chk_eq "M11b DAMAGE ORACLE: an unwritable record surface is never a DONE" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_contains "M11b the refusal carries the structural reason, not just an error" \
  "PUBLISH_INTERRUPTED" "$out"
chk_contains "M11b and states that nothing was published" "no terminal conclusion published" "$out"
chk_eq "M11b no record was left behind" 0 \
  "$([ -e "$WATCH_RUN_DIR/m11b.terminal.json" ] && echo 1 || echo 0)"
# the degradation is the documented one, and it is LOUD: an unwritable run dir also means no
# lease, so the supervisor cannot be established and the waiter says so before falling back
chk_contains "M11b the fallback to the in-process loop is announced, never silent" \
  "NOT kill-resilient" "$out"

# M12 — every way a record can be untrustworthy, judged with the supervisor already gone so the
# reader has to answer on the record alone. Each variant: fail closed, never DONE, never guessed.
seed m12 70000
printf '0\n' > "$WATCH_RUN_DIR/m12.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
bash "$AGENTCTL" watch m12 >/dev/null 2>&1
cp "$WATCH_RUN_DIR/m12.terminal.json" "$SANDBOX/m12.good.json"
export AGENT_WATCH_MAX_POLLS=1 AGENTCTL_SUPERVISOR_ARM_TRIES=5
damage() { # $1 label  $2 shell that installs the damaged record
  rm -f "$WATCH_RUN_DIR/m12.terminal.json"
  eval "$2"
  out="$(bash "$AGENTCTL" watch m12 2>&1)"; rc=$?
  chk_eq "M12 $1: never reported as DONE 0" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
  chk_not_contains "M12 $1: no DONE line" "=== [m12] DONE" "$out"
}
damage "truncated JSON" 'head -c 40 "$SANDBOX/m12.good.json" > "$WATCH_RUN_DIR/m12.terminal.json"'
damage "illegal class for the exit" \
  'python3 -c "import json,sys;m=json.load(open(sys.argv[1]));m[\"class\"]=\"DONE\";m[\"rc\"]=7;json.dump(m,open(sys.argv[2],\"w\"))" "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"'
damage "exit outside the terminal vocabulary" \
  'python3 -c "import json,sys;m=json.load(open(sys.argv[1]));m[\"rc\"]=99;m[\"class\"]=\"DONE\";json.dump(m,open(sys.argv[2],\"w\"))" "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"'
damage "record is a symlink out of the run dir" \
  'ln -s "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"'
damage "record is a fifo" 'mkfifo "$WATCH_RUN_DIR/m12.terminal.json"'
rm -f "$WATCH_RUN_DIR/m12.terminal.json"
damage "unreadable record" 'cp "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"; chmod 000 "$WATCH_RUN_DIR/m12.terminal.json"'
chmod 600 "$WATCH_RUN_DIR/m12.terminal.json"
# PAIRED GREEN: the undamaged record of the same session still reads as DONE
cp "$SANDBOX/m12.good.json" "$WATCH_RUN_DIR/m12.terminal.json"
out="$(bash "$AGENTCTL" watch m12 2>&1)"; rc=$?
chk_eq "M12 PAIRED GREEN: the intact record still reports DONE 0" 0 "$rc"
chk_contains "M12 PAIRED GREEN: with its own verdict line" "DONE" "$out"
unset AGENTCTL_SUPERVISOR_ARM_TRIES
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M13: two waiters, ONE supervisor, one answer =="
sw_sandbox
seed m13 70000; running m13
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m13 "$SANDBOX/m13.a.log"; A=$WPID_BG
watch_bg m13 "$SANDBOX/m13.b.log"; B=$WPID_BG
await "[ -s '$WATCH_RUN_DIR/m13.watch.super.json' ]" 100
/bin/sleep 2
chk_eq "M13 DAMAGE ORACLE: concurrent waiters established exactly ONE supervisor" 1 "$(spawn_count m13)"
chk_eq "M13 and exactly one sensing process is alive" 1 \
  "$(kill -0 "$(lease_pid m13)" 2>/dev/null && echo 1 || echo 0)"
printf '0\n' > "$WATCH_RUN_DIR/m13.duplex.rc"
wait "$A" 2>/dev/null; arc=$?
wait "$B" 2>/dev/null; brc=$?
chk_eq "M13 waiter A reports the fenced conclusion" 0 "$arc"
chk_eq "M13 waiter B reports the SAME fenced conclusion" 0 "$brc"
chk_eq "M13 one publish, not two (single authority)" 1 \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' \
      "$WATCH_RUN_DIR/m13.terminal.json")"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M14: stop / --interrupt retire the supervisor; late conclusions are refused =="
sw_sandbox

# stop mid-sensing: the loop is retired, and a conclusion it computes afterwards cannot land.
seed m14 70000; running m14
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m14 "$SANDBOX/m14.w.log"
await "[ -s '$WATCH_RUN_DIR/m14.watch.super.json' ]" 100
sup="$(lease_pid m14)"
armed="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token m14)"
bash "$AGENTCTL" stop m14 >/dev/null 2>&1
wait "$WPID_BG" 2>/dev/null
chk_eq "M14 DAMAGE ORACLE: stop reaped the sensing loop" 0 \
  "$(await "! kill -0 $sup 2>/dev/null" 100 && echo 0 || echo 1)"
chk_eq "M14 stop removed the supervisor lease" 0 \
  "$([ -e "$WATCH_RUN_DIR/m14.watch.super.json" ] && echo 1 || echo 0)"
# `--round` is REQUIRED by the publisher since R3, so the probe supplies the round this
# session is really on — otherwise the publish is refused for the missing fence and never
# reaches the identity fence under test.
pout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish m14 --armed "$armed" \
        --rc 0 --round 1 --detail "late conclusion from a stopped session" 2>&1)"; prc=$?
chk_eq "M14 a retired supervisor's late conclusion is refused" 2 "$prc"
chk_eq "M14 and it resurrected nothing" 0 \
  "$([ -e "$WATCH_RUN_DIR/m14.terminal.json" ] && echo 1 || echo 0)"

# --interrupt mid-sensing: new attempt, old supervisor retired, late conclusion fenced out.
seed m14r 70000; running m14r
mkfifo "$WATCH_RUN_DIR/m14r.duplex.in" 2>/dev/null || true
watch_bg m14r "$SANDBOX/m14r.w.log"
await "[ -s '$WATCH_RUN_DIR/m14r.watch.super.json' ]" 100
sup="$(lease_pid m14r)"
armed="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token m14r)"
bash "$AGENTCTL" steer m14r -m "start over" --interrupt >/dev/null 2>&1
chk_eq "M14 DAMAGE ORACLE: --interrupt reaped the supervisor armed under the old attempt" 0 \
  "$(await "! kill -0 $sup 2>/dev/null" 100 && echo 0 || echo 1)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity replace m14r >/dev/null 2>&1
pout="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish m14r --armed "$armed" \
        --rc 0 --round 1 --detail "late conclusion from the previous attempt" 2>&1)"; prc=$?
chk_eq "M14 the old attempt's late conclusion is refused" 2 "$prc"
chk_contains "M14 the refusal names the attempt fence" "STALE-ATTEMPT" "$pout"
wait "$WPID_BG" 2>/dev/null; wrc=$?
chk_eq "M14 the attached waiter is told, typed, that its supervisor is gone" 12 "$wrc"
# `--interrupt` retires the loop BEFORE the attempt actually rotates, so the honest word on the
# host surface is the retirement, not a fence class that has not fired yet — the fence class is
# asserted above, on the publish that really is refused. What must never happen is a silent or
# mysterious death: the waiter says it lost its supervisor AND why.
chk_contains "M14 the host surface names the lifecycle action that retired the loop" \
  "SUPERVISOR-RETIRED" "$(cat "$SANDBOX/m14r.w.log")"
chk_contains "M14 and points at the verb responsible" "--interrupt" "$(cat "$SANDBOX/m14r.w.log")"
chk_contains "M14 and states no conclusion was published" "no terminal conclusion published" \
  "$(cat "$SANDBOX/m14r.w.log")"
chk_not_contains "M14 a retired supervisor never yields a DONE" "=== [m14r] DONE" \
  "$(cat "$SANDBOX/m14r.w.log")"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M14b: the retirement note is published BEFORE the lease it explains disappears =="
sw_sandbox
# A waiter's typed 12 is produced by ONE observation: no lease. Retirement used to unlink the
# lease first and write its last words afterwards, so a waiter reading inside that window got a
# correct 12 with NO cause — safe, but a mystery death is exactly what the note exists to
# prevent, and the M14 relay assertions above went flaky (which teaches re-running to green).
# The window is too short to hit by polling, so this pins the WORST observation instant: an
# `rm` shim looks at the run dir the moment the lease is unlinked, and runs the canonical
# reader out of process — the read `agentctl watch` would have made had it polled right then.
#
# What is asserted is the ORDER (note on disk before the evidence that triggers the verdict),
# never which verdict the reader reaches: a conclusion published before the retirement landed
# outranks supervisor loss by design (`watch_state` priority 1), so pinning 12 here would be
# pinning a race. The reader is kept for the oracle below — whatever verdict it gives, a
# SUPERVISOR-LOST in this window must never be a bare one.
cat > "$BIN/rm" <<'EOF'
#!/usr/bin/env bash
tgt=""
for a in "$@"; do case "$a" in *.watch.super.json) tgt="$a";; esac; done
/bin/rm "$@"; rc=$?
if [ -n "$tgt" ] && [ -n "${RETIRE_PROBE_LOG:-}" ]; then
  d="${tgt%/*}"; s="${tgt##*/}"; s="${s%.watch.super.json}"
  { if [ -s "$d/$s.watch.super.exit" ]; then
      printf 'note-present: %s\n' "$(cat "$d/$s.watch.super.exit")"
    else printf 'note-absent\n'; fi
    python3 "$RETIRE_PROBE_CTL" --run-dir "$d" watch-state "$s" 2>&1; echo "rc=$?"
  } >> "$RETIRE_PROBE_LOG"
fi
exit "$rc"
EOF
chmod +x "$BIN/rm"
seed m14o 70000; running m14o
mkfifo "$WATCH_RUN_DIR/m14o.duplex.in" 2>/dev/null || true
export AGENT_WATCH_MAX_POLLS=1000
watch_bg m14o "$SANDBOX/m14o.w.log"
await "[ -s '$WATCH_RUN_DIR/m14o.watch.super.json' ]" 100
PROBE="$SANDBOX/m14o.probe.log"
RETIRE_PROBE_LOG="$PROBE" RETIRE_PROBE_CTL="$DUPLEXCTL" \
  bash "$AGENTCTL" steer m14o -m "start over" --interrupt >/dev/null 2>&1
wait "$WPID_BG" 2>/dev/null
probe="$(cat "$PROBE" 2>/dev/null)"
chk_contains "M14b the last words are already on disk when the lease is unlinked" \
  "note-present" "$probe"
chk_not_contains "M14b DAMAGE ORACLE: the lease never vanishes ahead of the note" \
  "note-absent" "$probe"
chk_contains "M14b and they name the lifecycle action that retired the loop" \
  "SUPERVISOR-RETIRED" "$probe"
chk_contains "M14b and the verb responsible" "--interrupt" "$probe"
chk_contains "M14b and state that nothing was concluded" "no terminal conclusion published" \
  "$probe"
chk_eq "M14b DAMAGE ORACLE: no SUPERVISOR-LOST read in that window is left without last words" \
  "$(printf '%s\n' "$probe" | grep -c 'SUPERVISOR-LOST')" \
  "$(printf '%s\n' "$probe" | grep -c "supervisor's last words")"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== legacy --inline: the pre-supervised loop is still exactly available =="
sw_sandbox
seed lg 70000
printf '0\n' > "$WATCH_RUN_DIR/lg.duplex.rc"
export AGENT_WATCH_MAX_POLLS=6
out="$(bash "$AGENTCTL" watch lg --inline 2>&1)"; rc=$?
chk_eq "--inline reaches the same DONE 0" 0 "$rc"
chk_eq "--inline keeps the machine-readable tail" "EXIT=0" "$(printf '%s\n' "$out" | tail -1)"
chk_eq "DAMAGE ORACLE: --inline establishes NO supervisor (that is the point of the flag)" 0 \
  "$(spawn_count lg)"
seed lg2 70000; running lg2
export AGENT_WATCH_MAX_POLLS=2
out="$(bash "$AGENTCTL" watch lg2 --inline 2>&1)"; rc=$?
chk_eq "--inline still exits 7 on its own budget" 7 "$rc"
chk_eq "DAMAGE ORACLE: and --inline persists NOTHING for a non-DONE class (the old loss mode)" 0 \
  "$([ -e "$WATCH_RUN_DIR/lg2.terminal.json" ] && echo 1 || echo 0)"
out="$(bash "$AGENTCTL" watch lg2 --bogus 2>&1)"; rc=$?
chk_eq "an unknown watch option is refused, never silently treated as a session" 1 "$rc"
chk_contains "and the refusal names the option" "unknown watch option" "$out"
sw_clean

# ═════════════════════════════════════════════════════════════════════════════════════════
# R2 — the review's eight execution probes, frozen as assertions. Every one of these was RED
# against the reviewed head (316ecb6) and is the reason the corresponding fix exists. Same
# rules as above: public CLI / canonical shipped reader / real signals only.
# ═════════════════════════════════════════════════════════════════════════════════════════

echo "== F-01: the shipped status / --inline publishers carry the round fence =="
sw_sandbox

# Deterministic version of "a plain steer lands between classify and publish": the identity
# lock is the publisher's own critical section, so holding it parks the shipped publisher at
# exactly that window while the test rotates the round underneath it.
hold_identity_lock() { # $1 session — sets HOLDER (pid); the lock is held until release_lock
  python3 - "$WATCH_RUN_DIR/$1.identity.lock" "$SANDBOX/$1.held" <<'PY' &
import fcntl, sys, time
with open(sys.argv[1], "a") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    time.sleep(120)
PY
  HOLDER=$!
  await "[ -e '$SANDBOX/$1.held' ]" 100
}
release_lock() { kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }

# --- status, the real shipped shape (no --round on the command line) ---------------------
seed f1s 70000
printf 'deliverable=%s\n' "$WT/f1s.md" >> "$WATCH_RUN_DIR/f1s.duplex.meta"
printf 'x\n' > "$WT/f1s.md"
printf '0\n' > "$WATCH_RUN_DIR/f1s.duplex.rc"
hold_identity_lock f1s
bash "$AGENTCTL" status f1s > "$SANDBOX/f1s.out" 2>&1 &
STPID=$!
/bin/sleep 3                     # classify is done; the publish is parked on the lock
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/f1s.duplex.meta"
rm -f "$WATCH_RUN_DIR/f1s.duplex.meta.bak"
release_lock
wait "$STPID" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/f1s.out")"
chk_eq "F-01 DAMAGE ORACLE: status cannot publish a round-1 conclusion into round 2" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_contains "F-01 status names the round fence" "STALE-ROUND" "$out"
chk_eq "F-01 and nothing was written" 0 \
  "$([ -e "$WATCH_RUN_DIR/f1s.terminal.json" ] && echo 1 || echo 0)"

# PAIRED GREEN: same shipped shape, no round rotation — status still publishes, stamped with
# the round it actually concluded.
seed f1p 70000
printf 'deliverable=%s\n' "$WT/f1p.md" >> "$WATCH_RUN_DIR/f1p.duplex.meta"
printf 'x\n' > "$WT/f1p.md"
printf '0\n' > "$WATCH_RUN_DIR/f1p.duplex.rc"
rc="$(bash "$AGENTCTL" status f1p >/dev/null 2>&1; echo $?)"
chk_eq "F-01 PAIRED GREEN: an unraced status publishes normally" 0 "$rc"
chk_eq "F-01 PAIRED GREEN: and the record is stamped with the round it concluded" "1" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["round"])' \
       "$WATCH_RUN_DIR/f1p.terminal.json" 2>/dev/null)"

# --- --inline, the other shipped publisher of a DONE marker ------------------------------
seed f1i 70000
printf '0\n' > "$WATCH_RUN_DIR/f1i.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
hold_identity_lock f1i
bash "$AGENTCTL" watch f1i --inline > "$SANDBOX/f1i.out" 2>&1 &
WPID=$!
/bin/sleep 5                     # two stable DONE reads happen at POLL=1; publish then parks
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/f1i.duplex.meta"
rm -f "$WATCH_RUN_DIR/f1i.duplex.meta.bak"
release_lock
wait "$WPID" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/f1i.out")"
chk_eq "F-01 DAMAGE ORACLE: --inline cannot publish a round-1 conclusion into round 2" 2 "$rc"
chk_contains "F-01 the inline refusal names the round fence" "STALE-ROUND" "$out"
chk_eq "F-01 and the inline publisher wrote nothing" 0 \
  "$([ -e "$WATCH_RUN_DIR/f1i.terminal.json" ] && echo 1 || echo 0)"
sw_clean

echo "== F-02: two attached waiters converge on the same non-DONE conclusion =="
sw_sandbox
seed f2 70000; running f2
export AGENT_WATCH_MAX_POLLS=1000
# different poll cadences: A reads the conclusion first and delivers it, B arrives seconds
# later. The record A rotated away must still be B's answer — B was attached the whole time.
AGENT_WATCH_POLL_SECS=1 bash "$AGENTCTL" watch f2 > "$SANDBOX/f2.a.log" 2>&1 &
FA=$!
AGENT_WATCH_POLL_SECS=5 bash "$AGENTCTL" watch f2 > "$SANDBOX/f2.b.log" 2>&1 &
FB=$!
await "[ -s '$WATCH_RUN_DIR/f2.watch.super.json' ]" 200
/bin/sleep 1
printf '3\n' > "$WATCH_RUN_DIR/f2.duplex.rc"     # real classify → FAILED 2
wait "$FA" 2>/dev/null; arc=$?
wait "$FB" 2>/dev/null; brc=$?
chk_eq "F-02 waiter A reports the class the supervisor published" 2 "$arc"
chk_eq "F-02 DAMAGE ORACLE: waiter B reports the SAME class, never SUPERVISOR-LOST" 2 "$brc"
chk_not_contains "F-02 B was never told its supervisor was lost" "SUPERVISOR-LOST" \
  "$(cat "$SANDBOX/f2.b.log")"
chk_eq "F-02 the delivered conclusion is retained, not destroyed" 1 \
  "$([ -s "$WATCH_RUN_DIR/f2.terminal.consumed.json" ] || [ -s "$WATCH_RUN_DIR/f2.terminal.json" ] \
     && echo 1 || echo 0)"
chk_eq "F-02 one supervisor served both" 1 "$(spawn_count f2)"
# and the delivery rule still holds its other end: a waiter that arms AFTER the conclusion was
# delivered senses again instead of replaying it (the duplex-lane re-arm contract). The oracle
# is the sensing, not the exit code — this waiter legitimately RE-DERIVES the same class from
# the same live facts (the rc file still says 3), and calling that a replay would pass for the
# wrong reason.
f2spawns="$(spawn_count f2)"
AGENT_WATCH_MAX_POLLS=1 AGENTCTL_SUPERVISOR_ARM_TRIES=5 bash "$AGENTCTL" watch f2 >/dev/null 2>&1
chk_eq "F-02 PAIRED: a waiter arming after delivery re-senses, it does not replay" 1 \
  "$([ "$(spawn_count f2)" -gt "$f2spawns" ] && echo 1 || echo 0)"
sw_clean

echo "== F-03: a null incarnation on both sides is undecidable, never a match =="
sw_sandbox
# no pane_pid at all: the incarnation signal is unobtainable, which is exactly the pair the
# fence used to collapse to '-' == '-'.
seed f3
chk_eq "F-03 arrange: the incarnation really is unestablished" "None" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["processIncarnation"])' \
       "$WATCH_RUN_DIR/f3.identity.d/active.json")"
printf '0\n' > "$WATCH_RUN_DIR/f3.duplex.rc"
export AGENT_WATCH_MAX_POLLS=1000
rc0="$(bash "$AGENTCTL" watch f3 >/dev/null 2>&1; echo $?)"
chk_eq "F-03 arrange: incarnation A published a real DONE record" 0 "$rc0"
tok_a="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f3)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity resume f3 >/dev/null 2>&1
tok_b="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f3)"
chk_eq "F-03 DAMAGE ORACLE: two unestablishable incarnations do NOT compare equal" 1 \
  "$([ "$tok_a" != "$tok_b" ] && echo 1 || echo 0)"
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state f3 --arm 2>&1)"; rc=$?
chk_eq "F-03 the canonical reader refuses the pre-resume DONE (13 = nothing adoptable)" 13 "$rc"
chk_contains "F-03 and says why it is not adoptable" "STALE-INCARNATION" "$out"
export AGENT_WATCH_MAX_POLLS=1 AGENTCTL_SUPERVISOR_ARM_TRIES=5
out="$(bash "$AGENTCTL" watch f3 2>&1)"; rc=$?
chk_eq "F-03 the public waiter never reports the old life's DONE" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_not_contains "F-03 no false DONE across the null/null boundary" "=== [f3] DONE" "$out"
unset AGENTCTL_SUPERVISOR_ARM_TRIES
sw_clean

echo "== F-04: the canonical reader's OWN timeout is typed 12, never business 8 =="
sw_sandbox
seed f4 70000; running f4
# a meta the reader can open but never finish reading: the canonical read blocks inside its
# own watchdog window, with no terminal record anywhere.
mv "$WATCH_RUN_DIR/f4.duplex.meta" "$SANDBOX/f4.meta.bak"
mkfifo "$WATCH_RUN_DIR/f4.duplex.meta"
out="$(AGENT_WATCH_STATUS_TIMEOUT=1 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state f4 2>&1)"; rc=$?
chk_eq "F-04 DAMAGE ORACLE: a reader that timed out returns 12, not the business class 8" 12 "$rc"
chk_contains "F-04 the class is the undecidable one" "SUPERVISOR-LOST" "$out"
chk_not_contains "F-04 and it is never dressed as an engine verdict" "ENGINE-SILENT" "$out"
rm -f "$WATCH_RUN_DIR/f4.duplex.meta"
cp "$SANDBOX/f4.meta.bak" "$WATCH_RUN_DIR/f4.duplex.meta"

# the same failure reached through the public waiter: attached, supervised, then the meta it
# reads through becomes unreadable while nothing has concluded.
seed f4w 70000; running f4w
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_STATUS_TIMEOUT=1
watch_bg f4w "$SANDBOX/f4w.log"
await "[ -s '$WATCH_RUN_DIR/f4w.watch.super.json' ]" 200
sup="$(lease_pid f4w)"
mkfifo "$SANDBOX/f4w.fifo"
mv "$SANDBOX/f4w.fifo" "$WATCH_RUN_DIR/f4w.duplex.meta"   # atomic swap: every later read blocks
kill -9 "$sup" 2>/dev/null                                 # only the waiter is left
wait "$WPID_BG" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/f4w.log")"
chk_eq "F-04 the public waiter types its own unreadable state as 12" 12 "$rc"
chk_not_contains "F-04 the waiter never reports ENGINE-SILENT for a read it could not finish" \
  "ENGINE-SILENT" "$out"
chk_eq "F-04 and no terminal record was invented" 0 \
  "$([ -e "$WATCH_RUN_DIR/f4w.terminal.json" ] && echo 1 || echo 0)"
rm -f "$WATCH_RUN_DIR/f4w.duplex.meta"
unset AGENT_WATCH_STATUS_TIMEOUT
sw_clean

echo "== F-05: a rogue same-name watchd is undecidable, not a licence to sense inline =="
sw_sandbox
seed f5 70000
printf '3\n' > "$WATCH_RUN_DIR/f5.duplex.rc"        # inline sensing would re-derive FAILED 2
export AGENT_WATCH_MAX_POLLS=1000 AGENTCTL_SUPERVISOR_ARM_TRIES=5
tmux new-session -d -s f5-watchd -c "$WT" '/bin/sleep 600'   # squats the name, never leases
out="$(bash "$AGENTCTL" watch f5 2>&1)"; rc=$?
chk_eq "F-05 DAMAGE ORACLE: the waiter returns typed 12, it does not fall back to inline" 12 "$rc"
chk_contains "F-05 the class is named" "SUPERVISOR-LOST" "$out"
chk_contains "F-05 the detail names the rogue watchd" "rogue" "$out"
chk_contains "F-05 and gives the cleanup instruction" "kill-session" "$out"
chk_not_contains "F-05 no business conclusion was re-derived inline" "=== [f5] FAILED" "$out"
chk_eq "F-05 nothing was published" 0 \
  "$([ -e "$WATCH_RUN_DIR/f5.terminal.json" ] && echo 1 || echo 0)"
chk_eq "F-05 the unidentifiable session was NOT murdered by the waiter" 1 \
  "$(tmux has-session -t "=f5-watchd" 2>/dev/null && echo 1 || echo 0)"
# PAIRED GREEN: clear the squatter and the canonical path supervises again
tmux kill-session -t "=f5-watchd" 2>/dev/null
unset AGENTCTL_SUPERVISOR_ARM_TRIES
out="$(bash "$AGENTCTL" watch f5 2>&1)"; rc=$?
chk_eq "F-05 PAIRED GREEN: with the name free, the supervised path reports the real class" 2 "$rc"
chk_contains "F-05 PAIRED GREEN: and it came from a published record" "FAILED" "$out"
sw_clean

echo "== F-06/F-07: the lease window covers a supported classify, and needs a start-time =="
sw_sandbox
seed f6 70000; running f6
f6tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f6)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease f6 \
  --armed "$f6tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
chk_eq "F-06 arrange: the shipped writer recorded a start-time for a live pid" 1 \
  "$(python3 -c 'import json,sys;print(1 if json.load(open(sys.argv[1]))["pidStart"] else 0)' \
       "$WATCH_RUN_DIR/f6.watch.super.json")"
age_lease() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' \
                "$WATCH_RUN_DIR/f6.watch.super.json" "$1"; }
age_lease 121
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state f6 2>&1)"; rc=$?
chk_eq "F-06 DAMAGE ORACLE: a 121s-old lease under a supported 300s classify is still alive" 10 "$rc"
chk_not_contains "F-06 no false wedge verdict during a legitimate slow classify" \
  "SUPERVISOR-LOST" "$out"
# Past the budget + slack the supervisor really IS wedged — but since R4 that verdict belongs
# to the POLLING waiter's own poll count and to nothing else. A one-shot read subtracts two
# mtimes, and a whole-host clock step lands them on opposite sides of the jump (review R3
# F-03), so it now makes no staleness claim at all. Same aged lease, both readers:
age_lease 400
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state f6 >/dev/null 2>&1; echo $?)"
chk_eq "F-06 a one-shot read derives no wedge from an age, however old the lease looks" 10 "$rc"
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state f6 --lease-unchanged 7 --poll 60 2>&1)"; rc=$?
chk_eq "F-06 PAIRED RED-SIDE: the self-clocking waiter past the budget + slack IS wedged" 12 "$rc"
chk_contains "F-06 and the detail names the wedge" "wedged" "$out"

# F-07 — the writer refuses a lease it cannot fence, using the shipped CLI and a broken `ps`
seed f7 70000
f7tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token f7)"
PSBIN7="$SANDBOX/psbin7"; mkdir -p "$PSBIN7"
cat > "$PSBIN7/ps" <<'FAKEPS'
#!/bin/sh
exit 1
FAKEPS
chmod +x "$PSBIN7/ps"
out="$(PATH="$PSBIN7:$PATH" python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease f7 \
       --armed "$f7tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 2>&1)"; rc=$?
chk_eq "F-07 DAMAGE ORACLE: a lease with no start-time is refused at the writer" 3 "$rc"
chk_contains "F-07 the refusal is typed" "SUPERVISOR-UNFENCEABLE" "$out"
chk_eq "F-07 and no unfenceable lease reached disk" 0 \
  "$([ -e "$WATCH_RUN_DIR/f7.watch.super.json" ] && echo 1 || echo 0)"
# reader side, defence in depth: a lease shaped like the one older writers produced (empty
# pidStart) must not read as alive just because some process holds that pid.
python3 - "$WATCH_RUN_DIR/f7.watch.super.json" "$f7tok" $$ <<'PY'
import json, sys
json.dump({"schemaVersion": 3, "pid": sys.argv[3], "pidStart": "", "identityToken": sys.argv[2],
           "tmux": "f7-watchd", "round": "1", "pollSecs": 1, "maxPolls": 1000, "iter": 1},
          open(sys.argv[1], "w"))
PY
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state f7 2>&1)"; rc=$?
chk_eq "F-07 DAMAGE ORACLE: same-pid without a start-time is undecidable, not alive" 12 "$rc"
chk_contains "F-07 and the detail says the pid alone proves nothing" "recycled" "$out"
sw_clean

# ═════════════════════════════════════════════════════════════════════════════════════════
# R3 — the R2 review's four findings, frozen as assertions. Every DAMAGE ORACLE below was RED
# against the reviewed head (2deda2e) and is the reason the corresponding fix exists. Same
# rules as above: public CLI / canonical shipped reader / real signals only; nothing here
# hand-writes a terminal record and reads it back.
# ═════════════════════════════════════════════════════════════════════════════════════════

strip_fields() { # $1 json file  $2.. keys to remove
  python3 - "$@" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    rec.pop(key, None)
json.dump(rec, open(sys.argv[1], "w"))
PY
}

echo "== G-01: the public publisher REQUIRES --round; the canonical reader REQUIRES class+round =="
sw_sandbox

# (a) `duplexctl identity publish` is the ONE identity surface for callers outside this
# process. Round 1 arms, the meta advances to round 2 (what a steer does), and the shipped
# publisher omits the fence: pre-fix it stamped the round the meta had reached BY THEN and a
# waiter reported the previous round's conclusion as this round's DONE.
seed g1 70000
printf '0\n' > "$WATCH_RUN_DIR/g1.duplex.rc"
g1tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token g1)"
sed -i.bak 's/^round=1$/round=2/' "$WATCH_RUN_DIR/g1.duplex.meta"
rm -f "$WATCH_RUN_DIR/g1.duplex.meta.bak"
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish g1 \
       --armed "$g1tok" --rc 0 2>&1)"; rc=$?
chk_eq "G-01 DAMAGE ORACLE: a publish with no round fence is REFUSED, never defaulted" 1 \
  "$([ "$rc" != 0 ] && echo 1 || echo 0)"
chk_contains "G-01 and the refusal names the missing fence" "--round" "$out"
chk_eq "G-01 and nothing was published" 0 \
  "$([ -e "$WATCH_RUN_DIR/g1.terminal.json" ] && echo 1 || echo 0)"
rc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1 --arm >/dev/null 2>&1; echo $?)"
chk_eq "G-01 so the canonical reader has nothing to adopt (13 = proceed to arm)" 13 "$rc"
# PAIRED GREEN: the same shipped publisher WITH the fence, for the round the meta is on
prc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish g1 \
       --armed "$g1tok" --rc 0 --round 2 >/dev/null 2>&1; echo $?)"
chk_eq "G-01 PAIRED GREEN: the fenced publish still succeeds" 0 "$prc"
chk_eq "G-01 PAIRED GREEN: and the record carries the round it concluded" "2" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["round"])' \
       "$WATCH_RUN_DIR/g1.terminal.json" 2>/dev/null)"

# (b) the read side of the same contract: `class` and `round` are REQUIRED schema fields of the
# canonical read, not compatibility options. Pre-fix a record with neither was adopted as DONE
# (`class is None && rc == 0` was completed to DONE, `round is None` skipped the round fence).
seed g1r 70000
printf '0\n' > "$WATCH_RUN_DIR/g1r.duplex.rc"
g1rtok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token g1r)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish g1r \
  --armed "$g1rtok" --rc 0 --round 1 >/dev/null 2>&1
G1REC="$WATCH_RUN_DIR/g1r.terminal.json"
chk_eq "G-01 arrange: the shipped publisher produced a record" 1 \
  "$([ -s "$G1REC" ] && echo 1 || echo 0)"
rc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm >/dev/null 2>&1; echo $?)"
chk_eq "G-01 arrange: and it is adoptable while intact" 0 "$rc"
cp "$G1REC" "$SANDBOX/g1r.intact.json"
strip_fields "$G1REC" class
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm 2>&1)"; rc=$?
chk_eq "G-01 DAMAGE ORACLE: a record with no class is not adoptable" 13 "$rc"
chk_contains "G-01 and the reader names the missing class" "class" "$out"
cp "$SANDBOX/g1r.intact.json" "$G1REC"
strip_fields "$G1REC" round
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm 2>&1)"; rc=$?
chk_eq "G-01 DAMAGE ORACLE: a record with no round is not adoptable" 13 "$rc"
chk_contains "G-01 and the reader names the missing round" "round" "$out"
cp "$SANDBOX/g1r.intact.json" "$G1REC"
strip_fields "$G1REC" class round
rc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm >/dev/null 2>&1; echo $?)"
chk_eq "G-01 DAMAGE ORACLE: neither field present is still not a legacy DONE" 13 "$rc"
# PAIRED GREEN: restore the shipped record and the same reader adopts it again
cp "$SANDBOX/g1r.intact.json" "$G1REC"
rc="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g1r --arm >/dev/null 2>&1; echo $?)"
chk_eq "G-01 PAIRED GREEN: the intact record is still this round's DONE" 0 "$rc"
sw_clean

echo "== G-02: a FAILED steer must not destroy an attached peer's undelivered conclusion =="
sw_sandbox
seed g2 70000; running g2
export AGENT_WATCH_MAX_POLLS=1000
# A (poll 1) reports and rotates the conclusion; B (poll 8) is attached the whole time and has
# not read yet. Pre-fix `agentctl steer` unlinked terminal.json AND terminal.consumed.json
# before duplexctl even ran, so a steer that FAILED — no new round, no delivery — still
# destroyed the only copy of this round's conclusion and B came back SUPERVISOR-LOST 12.
AGENT_WATCH_POLL_SECS=1 bash "$AGENTCTL" watch g2 > "$SANDBOX/g2.a.log" 2>&1 &
GA=$!
AGENT_WATCH_POLL_SECS=8 bash "$AGENTCTL" watch g2 > "$SANDBOX/g2.b.log" 2>&1 &
GB=$!
await "[ -s '$WATCH_RUN_DIR/g2.watch.super.json' ]" 200
/bin/sleep 1
printf '3\n' > "$WATCH_RUN_DIR/g2.duplex.rc"     # real classify → FAILED 2
wait "$GA" 2>/dev/null; arc=$?
chk_eq "G-02 arrange: waiter A reported the published class" 2 "$arc"
chk_eq "G-02 arrange: and rotated it to consumed" 1 \
  "$([ -s "$WATCH_RUN_DIR/g2.terminal.consumed.json" ] && echo 1 || echo 0)"
sout="$(bash "$AGENTCTL" steer g2 -m 'next round please' 2>&1)"; src=$?
chk_eq "G-02 arrange: the steer really failed (the engine already has an rc)" 1 \
  "$([ "$src" != 0 ] && echo 1 || echo 0)"
chk_eq "G-02 arrange: and it opened no new round" "round=1" \
  "$(sed -n 's/^\(round=.*\)$/\1/p' "$WATCH_RUN_DIR/g2.duplex.meta")"
chk_eq "G-02 DAMAGE ORACLE: the failed steer destroyed no record" 1 \
  "$([ -s "$WATCH_RUN_DIR/g2.terminal.consumed.json" ] && echo 1 || echo 0)"
wait "$GB" 2>/dev/null; brc=$?
chk_eq "G-02 so the attached peer still converges on the SAME class" 2 "$brc"
chk_not_contains "G-02 and was never told its supervisor was lost" "SUPERVISOR-LOST" \
  "$(cat "$SANDBOX/g2.b.log")"
# PAIRED GREEN for the other half of the rule — that a SUCCESSFUL steer really does clear the
# records at the round-commit point — is `test/agentctl-duplex.test.sh`'s "steer opens a new
# round and clears the marker (F1)", which drives a live fake engine this sandbox has no room
# for. Both halves must hold: this suite pins the refusal, that one pins the commit.
sw_clean

echo "== G-03: event order comes from the persisted publish sequence, never from a wall clock =="
sw_sandbox
seed g3 70000
printf '3\n' > "$WATCH_RUN_DIR/g3.duplex.rc"      # real classify → FAILED 2
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_POLL_SECS=1
arc="$(bash "$AGENTCTL" watch g3 >/dev/null 2>&1; echo $?)"
chk_eq "G-03 arrange: the first waiter reported and delivered a real conclusion" 2 "$arc"
G3C="$WATCH_RUN_DIR/g3.terminal.consumed.json"
chk_eq "G-03 arrange: the delivered record is on disk" 1 "$([ -s "$G3C" ] && echo 1 || echo 0)"
chk_eq "G-03 arrange: and the arm-time watermark is that record's publish seq" "1" \
  "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity watermark g3)"
age_record() { python3 -c 'import os,sys,time;t=time.time()+float(sys.argv[2]);os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
# (a) PAIRED GREEN — the host clock stepped FORWARD after publication, so a record that was
# published while this peer was attached now looks an hour old. Attachment is a seq
# comparison, so the peer (watermark 0 = it saw no record when it armed) still adopts it.
age_record "$G3C" -3600
out="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g3 --arm --armed-seq 0 2>&1)"; rc=$?
chk_eq "G-03 an attached peer still gets the delivered class when the record looks old" 2 "$rc"
chk_contains "G-03 and it is the real business class, not a degrade" "FAILED" "$out"
# (b) DAMAGE ORACLE — the mirror image: the host clock stepped BACK after publication, so the
# spent record's mtime is in the FUTURE. Pre-fix (`consumed.st_mtime >= arm instant`) a waiter
# that armed AFTER delivery was mistaken for an attached peer and REPLAYED a consumed business
# class. The live facts now say DONE, so a replay and a re-sense are distinguishable.
age_record "$G3C" 3600
printf '0\n' > "$WATCH_RUN_DIR/g3.duplex.rc"
brc="$(bash "$AGENTCTL" watch g3 >/dev/null 2>&1; echo $?)"
chk_eq "G-03 DAMAGE ORACLE: a waiter arming after delivery re-senses (0), it never replays (2)" \
  0 "$brc"
chk_eq "G-03 and the re-sensed conclusion is a NEW record, not the spent one" "2" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' \
       "$WATCH_RUN_DIR/g3.terminal.json" 2>/dev/null)"
sw_clean

echo "== G-03b: lease freshness survives a reader whose wall clock jumped, in both directions =="
sw_sandbox
# The injection: a sitecustomize shim that steps THIS reader's time.time() and nothing else —
# the filesystem's clock, the lease and the supervisor are untouched. That is the shape of a
# host clock adjustment landing between the supervisor's last renewal and the waiter's read.
CLOCKSHIM="$SANDBOX/clockshim"; mkdir -p "$CLOCKSHIM"
cat > "$CLOCKSHIM/sitecustomize.py" <<'PY'
import os, time
_skew = float(os.environ.get("SW_FAKE_CLOCK_SKEW") or 0)
if _skew:
    _real = time.time
    time.time = lambda: _real() + _skew
PY
skewed="$(SW_FAKE_CLOCK_SKEW=1000 PYTHONPATH="$CLOCKSHIM" python3 -c 'import time;print(int(time.time()))')"
nowsec="$(python3 -c 'import time;print(int(time.time()))')"
chk_eq "G-03b PROOF THE INJECTION IS LIVE: the shim really moves the reader's clock" 1 \
  "$([ $((skewed - nowsec)) -ge 990 ] && echo 1 || echo 0)"
seed g4 70000; running g4
g4tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token g4)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease g4 \
  --armed "$g4tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
chk_eq "G-03b arrange: a valid, FRESH lease from the shipped writer" 1 \
  "$([ -s "$WATCH_RUN_DIR/g4.watch.super.json" ] && echo 1 || echo 0)"
out="$(SW_FAKE_CLOCK_SKEW=1000 PYTHONPATH="$CLOCKSHIM" AGENT_WATCH_STATUS_TIMEOUT=300 \
       python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g4 2>&1)"; rc=$?
chk_eq "G-03b DAMAGE ORACLE: a reader 1000s ahead does not call a fresh lease wedged" 10 "$rc"
chk_not_contains "G-03b and never invents a wedge from its own clock" "wedged" "$out"
# the polling waiter's own clock: N consecutive of ITS polls with an unmoved lease. The window
# comes from the budget the supervisor recorded (300s + 60s slack = 360s) over the reader's
# poll interval — 6 intervals of 60s here — and no clock is consulted at all, in either
# direction. R4 corrects the counting: n SAMPLES bound n-1 elapsed INTERVALS, because the first
# sample only establishes a baseline; reading 6 samples as 6 intervals fired the wedge after
# 300 observed seconds, inside the window a legitimately slow classify owns (review R3 F-02).
out="$(SW_FAKE_CLOCK_SKEW=-100000 PYTHONPATH="$CLOCKSHIM" AGENT_WATCH_STATUS_TIMEOUT=300 \
       python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g4 \
       --lease-unchanged 7 --poll 60 2>&1)"; rc=$?
chk_eq "G-03b a reader that watched 6 of its own 60s intervals pass unmoved says wedged" 12 "$rc"
chk_contains "G-03b and names the reader's own polls, not seconds" "polls" "$out"
rc="$(SW_FAKE_CLOCK_SKEW=-100000 PYTHONPATH="$CLOCKSHIM" AGENT_WATCH_STATUS_TIMEOUT=300 \
      python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-state g4 \
      --lease-unchanged 6 --poll 60 >/dev/null 2>&1; echo $?)"
chk_eq "G-03b PAIRED GREEN: one interval short of the window is still alive" 10 "$rc"
sw_clean

echo "== G-04: a lease whose freshness budget is not a finite positive number is damaged =="
sw_sandbox
seed g5 70000; running g5
g5tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token g5)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease g5 \
  --armed "$g5tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
G5L="$WATCH_RUN_DIR/g5.watch.super.json"
cp "$G5L" "$SANDBOX/g5.lease.intact.json"
damage_lease() { # $1 key  $2 python literal
  python3 - "$G5L" "$1" "$2" <<'PY'
import json, sys
lease = json.load(open(sys.argv[1]))
lease[sys.argv[2]] = eval(sys.argv[3])          # noqa: S307 — fixture, literal from the test
json.dump(lease, open(sys.argv[1], "w"))
PY
}
# The lease stays FRESH and its pid/start-time stay correct: the ONLY thing wrong is the
# budget. Pre-fix `float("Infinity")` made stale_after infinite, so a damaged lease could
# impersonate a live supervisor until the waiter's outer cap (~2h) bypassed it.
damage_lease statusTimeout '"Infinity"'
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state g5 2>&1)"; rc=$?
chk_eq "G-04 DAMAGE ORACLE: a non-finite freshness budget is typed 12, never alive" 12 "$rc"
chk_contains "G-04 the class is the undecidable one" "SUPERVISOR-LOST" "$out"
chk_contains "G-04 and the detail names the damaged field" "statusTimeout" "$out"
cp "$SANDBOX/g5.lease.intact.json" "$G5L"
damage_lease statusTimeout 'float("nan")'
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state g5 >/dev/null 2>&1; echo $?)"
chk_eq "G-04 a NaN budget is damaged too" 12 "$rc"
cp "$SANDBOX/g5.lease.intact.json" "$G5L"
damage_lease pollSecs '-1'
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state g5 >/dev/null 2>&1; echo $?)"
chk_eq "G-04 a negative poll interval is damaged too" 12 "$rc"
cp "$SANDBOX/g5.lease.intact.json" "$G5L"
damage_lease pollSecs '"300"'
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state g5 >/dev/null 2>&1; echo $?)"
chk_eq "G-04 a stringly-typed budget is damaged too — the schema is numbers" 12 "$rc"
cp "$SANDBOX/g5.lease.intact.json" "$G5L"
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state g5 >/dev/null 2>&1; echo $?)"
chk_eq "G-04 PAIRED GREEN: the undamaged lease from the shipped writer is alive" 10 "$rc"
sw_clean

# ═════════════════════════════════════════════════════════════════════════════════════════
# R4 — the R3 review's three findings, frozen as assertions. Each DAMAGE ORACLE below was RED
# against the reviewed head (3d21e40). Same rules as above: public CLI / canonical shipped
# reader / real classify exits only.
# ═════════════════════════════════════════════════════════════════════════════════════════

rec_seq() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["seq"])' \
              "$1" 2>/dev/null; }

echo "== H-01: the delivery watermark is per-ATTEMPT — a retired attempt cannot arm a waiter =="
sw_sandbox
seed h1 70000; running h1
export AGENT_WATCH_MAX_POLLS=1000
H1LIVE="$WATCH_RUN_DIR/h1.terminal.json"; H1CONS="$WATCH_RUN_DIR/h1.terminal.consumed.json"
# attempt A, round 1: a real classify, a real waiter, a real delivery — seq 1, rotated to
# consumed. Then a second publish through the ONE public identity surface — seq 2, live.
printf '3\n' > "$WATCH_RUN_DIR/h1.duplex.rc"
arc="$(AGENT_WATCH_POLL_SECS=1 bash "$AGENTCTL" watch h1 >/dev/null 2>&1; echo $?)"
chk_eq "H-01 arrange: attempt A published and delivered a real FAILED" 2 "$arc"
chk_eq "H-01 arrange: and the delivered record is attempt A's seq 1" "1" "$(rec_seq "$H1CONS")"
h1a="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token h1)"
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity publish h1 \
  --armed "$h1a" --rc 7 --round 1 >/dev/null 2>&1
chk_eq "H-01 arrange: attempt A also leaves an UNdelivered live record at seq 2" "2" \
  "$(rec_seq "$H1LIVE")"
# KNOWN POSITIVE — without it a fenced watermark of 0 could not be told from a watermark that
# cannot see records at all: inside attempt A the very same call reports 2.
chk_eq "H-01 KNOWN POSITIVE: inside its own attempt the watermark really does see both" "2" \
  "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity watermark h1)"
# the attempt rotates through the public identity CLI. The round does NOT advance and neither
# record is cleaned — exactly the residue a FAILED `steer --replace` leaves behind, since the
# replacement identity is committed before the frame that then fails to send.
python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity replace h1 >/dev/null 2>&1
h1b="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token h1)"
chk_eq "H-01 arrange: the attempt really rotated" 1 \
  "$([ -n "$h1b" ] && [ "$h1a" != "$h1b" ] && echo 1 || echo 0)"
chk_eq "H-01 arrange: the round did not advance" "round=1" \
  "$(sed -n 's/^\(round=.*\)$/\1/p' "$WATCH_RUN_DIR/h1.duplex.meta")"
chk_eq "H-01 arrange: and both of attempt A's records survive the rotation" 1 \
  "$([ -s "$H1LIVE" ] && [ -s "$H1CONS" ] && echo 1 || echo 0)"
chk_eq "H-01 DAMAGE ORACLE: a retired attempt's records contribute NOTHING to the watermark" \
  "0" "$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity watermark h1)"
# and the end-to-end shape that made it a blocker: attempt B's publish sequence restarts at 1,
# so a waiter armed at the retired attempt's watermark read attempt B's FIRST conclusion as
# "published before I attached" and fell through to SUPERVISOR-LOST 12 while its peer — the
# same supervisor, the same terminal event — reported the business class. 2/12 on one event.
rm -f "$WATCH_RUN_DIR/h1.duplex.rc"          # back to RUNNING, so BOTH waiters attach first
rm -f "$WATCH_RUN_DIR/h1.watch.super.json"
tmux kill-session -t h1-watchd 2>/dev/null   # phase 1's supervisor exited on its own; free the
                                             # harness's session slot so exactly ONE new sensing
                                             # loop serves both waiters (a second one would
                                             # publish a second time and blur the sequence)
running h1
AGENT_WATCH_POLL_SECS=1 bash "$AGENTCTL" watch h1 > "$SANDBOX/h1.a.log" 2>&1 &
HA=$!
# B polls slowly enough that A is guaranteed to have reported AND rotated the record first:
# the delivered-record path is the one the watermark bug lived on.
AGENT_WATCH_POLL_SECS=12 bash "$AGENTCTL" watch h1 > "$SANDBOX/h1.b.log" 2>&1 &
HB=$!
await "[ -s '$WATCH_RUN_DIR/h1.watch.super.json' ]" 200
/bin/sleep 1
printf '3\n' > "$WATCH_RUN_DIR/h1.duplex.rc"     # real classify → FAILED 2, under attempt B
wait "$HA" 2>/dev/null; harc=$?
wait "$HB" 2>/dev/null; hbrc=$?
chk_eq "H-01 the fast waiter reports attempt B's real class" 2 "$harc"
chk_eq "H-01 arrange: and it IS attempt B's first publish (the sequence restarted at 1)" "1" \
  "$(rec_seq "$H1CONS")"
chk_eq "H-01 the attached peer converges on the SAME typed class, not 12" 2 "$hbrc"
chk_not_contains "H-01 and was never told its supervisor was lost" "SUPERVISOR-LOST" \
  "$(cat "$SANDBOX/h1.b.log")"
sw_clean

echo "== H-02: the wedge threshold counts elapsed INTERVALS, not lease samples =="
sw_sandbox
seed h2 70000; running h2
h2tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token h2)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease h2 \
  --armed "$h2tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
chk_eq "H-02 arrange: a valid lease recording a 300s classify budget" "300" \
  "$(python3 -c 'import json,sys;print(int(json.load(open(sys.argv[1]))["statusTimeout"]))' \
       "$WATCH_RUN_DIR/h2.watch.super.json")"
# window = max(4×1, 120, 300+60) = 360s; a 60s waiter poll must therefore observe 6 elapsed
# intervals, which takes 7 consecutive samples. N-1 must NOT judge, N must.
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h2 --lease-unchanged 6 --poll 60 2>&1)"; rc=$?
chk_eq "H-02 DAMAGE ORACLE: 6 samples bound only 300s — inside the 360s window, still alive" \
  10 "$rc"
chk_not_contains "H-02 and the legitimately slow classify is never called wedged" "wedged" "$out"
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h2 --lease-unchanged 7 --poll 60 2>&1)"; rc=$?
chk_eq "H-02 PAIRED RED-SIDE: the 7th sample completes 6 intervals = 360s and IS wedged" 12 "$rc"
chk_contains "H-02 and the detail counts intervals, not samples" "intervals" "$out"
# the same boundary at a different granularity, so the assertion pins the ARITHMETIC and not
# one lucky pair of numbers: a 30s poll needs 12 intervals = 13 samples for the same window.
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h2 --lease-unchanged 12 --poll 30 >/dev/null 2>&1; echo $?)"
chk_eq "H-02 a 30s poll is still alive at 12 samples (11 intervals = 330s)" 10 "$rc"
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h2 --lease-unchanged 13 --poll 30 >/dev/null 2>&1; echo $?)"
chk_eq "H-02 and wedged at 13 (12 intervals = 360s)" 12 "$rc"
# the floor still holds: a poll interval wider than the whole window must still observe two
# intervals — one missed renewal is not a wedge.
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h2 --lease-unchanged 2 --poll 3600 >/dev/null 2>&1; echo $?)"
chk_eq "H-02 FLOOR: one huge interval is not yet a wedge" 10 "$rc"
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h2 --lease-unchanged 3 --poll 3600 >/dev/null 2>&1; echo $?)"
chk_eq "H-02 FLOOR: two of them are" 12 "$rc"
sw_clean

echo "== H-03: a one-shot reader has no stall authority — lease age is never its evidence =="
sw_sandbox
seed h3 70000; running h3
h3tok="$(python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" identity token h3)"
AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" watch-lease h3 \
  --armed "$h3tok" --pid $$ --poll 1 --max-polls 1000 --iter 1 >/dev/null 2>&1
H3L="$WATCH_RUN_DIR/h3.watch.super.json"
cp "$H3L" "$SANDBOX/h3.lease.intact.json"
# A WHOLE-HOST clock step forward after the last renewal, which is what the previous `fs_now`
# probe could not survive: probe mtime and lease mtime share one clock domain but sit on
# opposite sides of the jump. Moving the lease mtime 1000s back produces the identical
# subtraction from the identical filesystem clock — and the supervisor is demonstrably fine.
python3 -c 'import os,sys,time; t=time.time()-1000.0; os.utime(sys.argv[1],(t,t))' "$H3L"
chk_eq "H-03 arrange: the lease names a live pid with a matching start-time (this shell)" "$$" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$H3L")"
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h3 2>&1)"; rc=$?
chk_eq "H-03 DAMAGE ORACLE: a 1000s filesystem-clock step never makes a one-shot read say 12" \
  10 "$rc"
chk_not_contains "H-03 and the one-shot line claims no staleness at all" "wedged" "$out"
chk_contains "H-03 it says so out loud, so nobody re-derives an age from it" "one-shot" "$out"
# the authority MOVED, it was not deleted: the polling waiter still wedges on the same lease...
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h3 --lease-unchanged 7 --poll 60 >/dev/null 2>&1; echo $?)"
chk_eq "H-03 PAIRED RED-SIDE: the self-clocking waiter still calls this lease wedged" 12 "$rc"
# ...and the one-shot read keeps every STRUCTURAL refusal it ever had. Dropping the age check
# must not quietly drop the schema, fence and pid-reuse gates with it.
damage_h3() { # $1 key  $2 python literal
  python3 - "$H3L" "$1" "$2" <<'PY'
import json, sys
lease = json.load(open(sys.argv[1]))
lease[sys.argv[2]] = eval(sys.argv[3])          # noqa: S307 — fixture, literal from the test
json.dump(lease, open(sys.argv[1], "w"))
PY
}
damage_h3 statusTimeout '"Infinity"'
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h3 >/dev/null 2>&1; echo $?)"
chk_eq "H-03 a damaged budget is still typed 12 for the one-shot reader" 12 "$rc"
cp "$SANDBOX/h3.lease.intact.json" "$H3L"
damage_h3 pidStart '""'
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h3 2>&1)"; rc=$?
chk_eq "H-03 a lease with no start-time is still typed 12 for the one-shot reader" 12 "$rc"
chk_contains "H-03 and still names pid reuse as the reason" "recycled" "$out"
cp "$SANDBOX/h3.lease.intact.json" "$H3L"
damage_h3 identityToken '"someone/elses/attempt"'
out="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
       watch-state h3 2>&1)"; rc=$?
chk_eq "H-03 a lease fenced to another identity is still typed 12" 12 "$rc"
chk_contains "H-03 and still names the fence" "STALE-" "$out"
cp "$SANDBOX/h3.lease.intact.json" "$H3L"
rc="$(AGENT_WATCH_STATUS_TIMEOUT=300 python3 "$DUPLEXCTL" --run-dir "$WATCH_RUN_DIR" \
      watch-state h3 >/dev/null 2>&1; echo $?)"
chk_eq "H-03 PAIRED GREEN: the intact lease reads alive again" 10 "$rc"
sw_clean

# ─────────────────────────────────────────────────────────────────────────────────────────
echo "== M16 STALLED-PROGRESS: streaming is not progress =="
# Field motive (2026-08-28, downstream seat): watch only called a human on a terminal state or
# a question, so 2.5h of healthy STREAMING with zero commits, zero deliverable bytes and no
# BLOCKED.md went unnoticed. STALLED-STREAM cannot see it — the stream is alive. The probe is
# the WORK TRACE: HEAD, the dirty-tree hash, the deliverable mtime, BLOCKED.md's mtime.
sw_sandbox
export AGENT_WATCH_STALL_MINS=0          # isolate: the STREAM probe must not answer for this
# a real repo with a real commit — `git rev-parse HEAD` on a commit-less repo is UNJUDGEABLE,
# which is a different case (proven as the third fixture below)
REPO="$SANDBOX/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
progress_seed() { # $1 session  $2 cwd
  seed "$1" && running "$1"
  printf 'engine=claude\ncwd=%s\nround=1\n' "$2" > "$WATCH_RUN_DIR/$1.duplex.meta"
}
# window in MINUTES; 0.01 = 0.6s, so two real polls straddle it without a slow test
PW=0.01

# ── 坏红: the trace is frozen for the whole window → typed STALLED-PROGRESS 14 ────────────
progress_seed pgFROZEN "$REPO"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgFROZEN >/dev/null 2>&1; echo $?)"
chk_eq "M16 the first read only OPENS the window (still RUNNING 10)" 10 "$rc"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgFROZEN 2>&1)"; rc=$?
chk_eq "M16 DAMAGE ORACLE: a frozen work trace past the window is typed 14" 14 "$rc"
chk_contains "M16 the verdict names the frozen probes" "dirty-tree hash" "$out"
chk_contains "M16 and never reads as done" "never read this as DONE" "$out"
chk_contains "M16 and names the knob that tunes it" "AGENT_WATCH_PROGRESS_MINS" "$out"
# the state must also be PUBLISHABLE — the terminal-class map gates that, and the supervisor
# leg below proves the whole path end to end
chk_contains "M16 the class is in the publishable terminal map" "STALLED-PROGRESS" \
  "$(grep -A2 'TERMINAL_CLASSES = ' "$AW_DIR/identity.py")"

# ── 好绿: the trace MOVES between reads → the window restarts, no verdict ─────────────────
progress_seed pgMOVES "$REPO"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgMOVES >/dev/null 2>&1; echo $?)"
chk_eq "M16 PAIRED GREEN: window opened (RUNNING 10)" 10 "$rc"
/bin/sleep 1
printf 'real work\n' > "$REPO/work.txt"          # the dirty-tree hash moves: that IS progress
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgMOVES 2>&1)"; rc=$?
chk_eq "M16 PAIRED GREEN: a moving work trace stays RUNNING 10 past the same window" 10 "$rc"
chk_contains "M16 PAIRED GREEN: and publishes when it last moved" "last_progress_at=" "$out"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgMOVES 2>&1)"; rc=$?
chk_eq "M16 PAIRED GREEN: the window really restarted from the movement, not from arm time" \
  14 "$rc"

# ── 坏样本 (SHIP-BLOCKING, cold review R1 §3): NESTED untracked content, edited every window ─
# The DEFAULT `git status --porcelain` folds nested untracked content into ONE `?? nested/`
# line. Appending to `nested/deep/notes.md` changes neither that porcelain set nor the listed
# directory's mtime, so real uncommitted work read as a frozen trace and fired a false 14.
# `--untracked-files=all` is what makes the nested FILE the dirty entry the mtime tracks.
progress_seed pgNEST "$REPO"
mkdir -p "$REPO/nested/deep"
printf 'v1\n' > "$REPO/nested/deep/notes.md"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgNEST >/dev/null 2>&1; echo $?)"
chk_eq "M16 nested: the first read only OPENS the window (RUNNING 10)" 10 "$rc"
/bin/sleep 1
printf 'v2\n' >> "$REPO/nested/deep/notes.md"    # ONLY the nested untracked file moves
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgNEST 2>&1)"; rc=$?
chk_eq "M16 PAIRED GREEN (坏样本): editing a NESTED untracked file IS progress, past the window" \
  10 "$rc"
chk_contains "M16 nested: and the window restarted from that movement" "last_progress_at=" "$out"
/bin/sleep 1
printf 'v3\n' >> "$REPO/nested/deep/notes.md"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgNEST >/dev/null 2>&1; echo $?)"
chk_eq "M16 nested: still no false verdict across a SECOND window of nested-only work" 10 "$rc"
# DAMAGE ORACLE: the very same tree, with that file left ALONE, really does freeze — so the
# green above is the fingerprint tracking the work, not the probe having been switched off
/bin/sleep 1
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgNEST >/dev/null 2>&1; echo $?)"
chk_eq "M16 nested DAMAGE ORACLE: stop editing it and the same window fires 14" 14 "$rc"
rm -rf "$REPO/nested"

# ── 坏样本 (SHIP-BLOCKING, verify R2 SB3): a dirty set PAST the bounded scan ──────────────
# The scan stats at most PROGRESS_DIRTY_MAX paths. Silently keeping the first 500 published a
# mtime measured over a PREFIX as if it covered the tree: with 501 dirty files, work that only
# ever touched the 501st left the fingerprint bit-identical and fired a false 14 on a session
# that was moving. The bound stays — the READING is refused instead of truncated.
BIG="$SANDBOX/bigrepo"; mkdir -p "$BIG"
git -C "$BIG" init -q 2>/dev/null
git -C "$BIG" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
python3 -c '
import os, sys
root = sys.argv[1]
for n in range(1, 502):
    with open(os.path.join(root, "f%03d.txt" % n), "w") as fh:
        fh.write("v1\n")' "$BIG"
chk_eq "M16 501 files: the fixture really is ONE past the bound" 501 \
  "$(git -C "$BIG" status --porcelain --untracked-files=all | grep -c .)"
progress_seed pgBIG "$BIG"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG >/dev/null 2>&1; echo $?)"
chk_eq "M16 501 files: first read RUNNING" 10 "$rc"
/bin/sleep 1
printf 'v2\n' >> "$BIG/f501.txt"       # ONLY the file OUTSIDE the scanned prefix moves
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG 2>&1)"; rc=$?
chk_eq "M16 DAMAGE ORACLE (SB3): work outside the scanned prefix NEVER fires 14" 10 "$rc"
chk_contains "M16 501 files: the read is admitted unjudgeable" "progress=unknown" "$out"
chk_contains "M16 501 files: and NAMES the bound it went past" \
  "exceeds the bounded scan (>500 paths)" "$out"
chk_not_contains "M16 501 files: no timestamp fabricated from a truncated measurement" \
  "last_progress_at=" "$out"
/bin/sleep 1
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG >/dev/null 2>&1; echo $?)"
chk_eq "M16 501 files: still no verdict across a SECOND window" 10 "$rc"
# PAIRED GREEN: the bound is not an off-switch. At exactly 500 dirty paths the same tree is
# JUDGED again, and a frozen one still fires the state it must.
rm -f "$BIG/f501.txt"
progress_seed pgBIG2 "$BIG"
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG2 2>&1)"; rc=$?
chk_eq "M16 PAIRED GREEN: 500 dirty paths opens a JUDGED window (RUNNING 10)" 10 "$rc"
chk_not_contains "M16 PAIRED GREEN: nothing unjudgeable about the bound itself" \
  "progress=unknown" "$out"
/bin/sleep 1
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBIG2 >/dev/null 2>&1; echo $?)"
chk_eq "M16 PAIRED GREEN: and a frozen 500-path tree still fires 14" 14 "$rc"
rm -rf "$BIG"

# ── 量具坏: a probe that cannot be JUDGED reads as progress, forever ──────────────────────
# cwd is not a repo, so `git rev-parse HEAD` fails: 宁钝勿敏 — an unjudgeable gauge may never
# manufacture a verdict, no matter how long it stays unjudgeable.
progress_seed pgBLIND "$SANDBOX/not-a-repo"
mkdir -p "$SANDBOX/not-a-repo"
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBLIND >/dev/null 2>&1; echo $?)"
chk_eq "M16 量具坏: first read RUNNING" 10 "$rc"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBLIND 2>&1)"; rc=$?
chk_eq "M16 量具坏: an unjudgeable git probe NEVER fires the state" 10 "$rc"
# NB3.3: unjudgeable only FORBIDS the verdict. It may not refresh the progress timestamp —
# a gauge failing at 14:03 is not the work moving at 14:03 (cold review R1 §3).
chk_contains "M16 量具坏: and SAYS the probe could not be judged" "progress=unknown" "$out"
chk_not_contains "M16 量具坏: publishing NO timestamp it never measured" \
  "last_progress_at=" "$out"
/bin/sleep 1
rc="$(AGENT_WATCH_PROGRESS_MINS=$PW bash "$AGENTCTL" status pgBLIND >/dev/null 2>&1; echo $?)"
chk_eq "M16 量具坏: still RUNNING after a third window" 10 "$rc"
# and the knob's off switch is real: 0 disables the probe entirely, even on a frozen repo
progress_seed pgOFF "$REPO"
rc="$(AGENT_WATCH_PROGRESS_MINS=0 bash "$AGENTCTL" status pgOFF >/dev/null 2>&1; echo $?)"
/bin/sleep 1
out="$(AGENT_WATCH_PROGRESS_MINS=0 bash "$AGENTCTL" status pgOFF 2>&1)"; rc=$?
chk_eq "M16 the 0 off-switch keeps the session RUNNING" 10 "$rc"
chk_not_contains "M16 and publishes no progress timestamp at all" "last_progress_at=" "$out"

# ── the SUPERVISOR must publish it like any other class, and a fresh waiter recover exit 14 ─
progress_seed pgSUP "$REPO"
export AGENT_WATCH_MAX_POLLS=1000 AGENT_WATCH_PROGRESS_MINS=$PW
if kill_waiter_then pgSUP ':'; then
  chk_eq "M16 the TERM'd waiter really died (143)" 143 "$W1RC"
  chk_eq "M16 STALLED-PROGRESS persisted by the supervisor" "STALLED-PROGRESS" \
    "$(record_class pgSUP)"
  before="$(spawn_count pgSUP)"
  out="$(bash "$AGENTCTL" watch pgSUP 2>&1)"; rc=$?
  chk_eq "M16 a brand-new waiter recovers exit 14 from the record" 14 "$rc"
  chk_contains "M16 and reproduces the class line" "STALLED-PROGRESS" "$out"
  chk_eq "M16 recovery re-derived nothing (no second supervisor)" "$before" "$(spawn_count pgSUP)"
else
  _record "M16 the supervisor published a STALLED-PROGRESS record" 0 "no record appeared"
fi
unset AGENT_WATCH_MAX_POLLS AGENT_WATCH_PROGRESS_MINS AGENT_WATCH_STALL_MINS

# ── WATCH-TIMEOUT must say WHICH kind of budget exhaustion it was ─────────────────────────
progress_seed pgTMO "$REPO"
export AGENT_WATCH_MAX_POLLS=3
out="$(AGENT_WATCH_PROGRESS_MINS=30 bash "$AGENTCTL" watch pgTMO 2>&1)"; rc=$?
chk_eq "M16 budget exhaustion is still WATCH-TIMEOUT 7" 7 "$rc"
chk_contains "M16 and the line ends with the progress verdict" "progress=unchanged" "$out"
unset AGENT_WATCH_MAX_POLLS
progress_seed pgTMO2 "$REPO"
export AGENT_WATCH_MAX_POLLS=8 AGENT_WATCH_PROGRESS_MINS=30
# ORDERING, not sleeping: the work must move AFTER the loop's first read established the
# baseline window, otherwise the very first fingerprint already contains it and "unchanged"
# would be the honest answer
watch_bg pgTMO2 "$SANDBOX/pgTMO2.w.log"
await "[ -s '$WATCH_RUN_DIR/pgTMO2.duplex.progress' ]" 300
printf 'more work\n' >> "$REPO/work.txt"
wait "$WPID_BG" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/pgTMO2.w.log")"
chk_eq "M16 PAIRED GREEN: a working session times out the same way" 7 "$rc"
chk_contains "M16 PAIRED GREEN: but the tail says the work DID move" "progress=changed" "$out"
unset AGENT_WATCH_PROGRESS_MINS
# NB3.3: the THIRD tail word is the honest one. A cwd that is not a repo makes every read
# unjudgeable, and `unchanged` there would be a measurement nobody took (cold review R1 §3).
progress_seed pgTMO3 "$SANDBOX/not-a-repo"
export AGENT_WATCH_MAX_POLLS=3 AGENT_WATCH_PROGRESS_MINS=30
out="$(bash "$AGENTCTL" watch pgTMO3 2>&1)"; rc=$?
chk_eq "M16 an unjudgeable probe still times out as WATCH-TIMEOUT 7" 7 "$rc"
chk_contains "M16 NB3.3: and the tail word is unknown, not a fabricated unchanged" \
  "progress=unknown" "$out"
chk_not_contains "M16 NB3.3: never claiming the trace stood still" "progress=unchanged" "$out"
# NB3.3 恢复面 (verify R2): the gauge comes BACK mid-watch, on a tree that never changed.
# The first judgeable read only rebuilds a baseline — the window it replaces was opened by a
# read nobody could judge, so the difference between the two fingerprints is unattributed.
# Crediting it as movement moved the progress clock to the RECOVERY instant, and the
# `None → SAME → SAME` sequence below then reported `progress=changed` on a session that
# never demonstrably moved a byte.
pg_field() { # $1 session  $2 field of the persisted progress window
  python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else json.dumps(v))' "$WATCH_RUN_DIR/$1.duplex.progress" "$2"
}
RECO="$SANDBOX/recover"; mkdir -p "$RECO"
progress_seed pgREC "$RECO"
export AGENT_WATCH_MAX_POLLS=8 AGENT_WATCH_PROGRESS_MINS=30
watch_bg pgREC "$SANDBOX/pgREC.w.log"
await "[ -s '$WATCH_RUN_DIR/pgREC.duplex.progress' ]" 300
chk_eq "M16 NB3.3 恢复: the window really was opened by an UNJUDGEABLE read" "false" \
  "$(pg_field pgREC judgeable)"
# ORDERING, not sleeping: the gauge must recover AFTER that first blind read, on an
# UNCHANGED tree — the whole point is that nobody measured whether work moved before it
git -C "$RECO" init -q 2>/dev/null
git -C "$RECO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
wait "$WPID_BG" 2>/dev/null; rc=$?
out="$(cat "$SANDBOX/pgREC.w.log")"
chk_eq "M16 NB3.3 恢复: budget exhaustion is still WATCH-TIMEOUT 7" 7 "$rc"
chk_eq "M16 NB3.3 恢复: and the gauge REALLY recovered — this is not the blind case again" \
  "true" "$(pg_field pgREC judgeable)"
chk_eq "M16 NB3.3 恢复: the recovery rebuilt a baseline and credited NO movement" "0.0" \
  "$(pg_field pgREC moved)"
chk_contains "M16 NB3.3 恢复: so the tail word is unknown" "progress=unknown" "$out"
chk_not_contains "M16 NB3.3 恢复 DAMAGE ORACLE: never the fabricated changed" \
  "progress=changed" "$out"
chk_not_contains "M16 NB3.3 恢复: and never a fabricated unchanged either" \
  "progress=unchanged" "$out"
unset AGENT_WATCH_MAX_POLLS AGENT_WATCH_PROGRESS_MINS
unset AGENT_WATCH_MAX_POLLS AGENT_WATCH_PROGRESS_MINS
unset AGENT_WATCH_MAX_POLLS
sw_clean

summary
